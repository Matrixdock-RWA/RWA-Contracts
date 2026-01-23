module messenger_lz::messenger_oapp;

use call::call::{Call, Void};
use call::call_cap::CallCap;
use endpoint_v2::endpoint_quote::QuoteParam;
use endpoint_v2::endpoint_send::SendParam;
use endpoint_v2::endpoint_v2::EndpointV2;
use endpoint_v2::lz_receive::LzReceiveParam;
use endpoint_v2::messaging_channel::MessagingChannel;
use endpoint_v2::messaging_fee::MessagingFee;
use endpoint_v2::messaging_receipt::MessagingReceipt;
use endpoint_v2::utils as ep_utils;
use mtoken::mtoken::{Self, MessengerCap, State as MtState};
use oapp::endpoint_calls;
use oapp::oapp::{Self, AdminCap, OApp};
use oapp::oapp_info_v1;
use std::type_name;
use sui::address;
use sui::coin::Coin;
use sui::event;
use sui::package::UpgradeCap;
use sui::sui::SUI;
use sui::table::{Self, Table};
use utils::bytes32::{Self, Bytes32};
use utils::table_ext;
use xaum::xaum::XAUM;

// === Errors ===
const EWrongVersion: u64 = 1;
const ENotOwner: u64 = 2;
const EPaused: u64 = 3;
const ENoMessengerCap: u64 = 4;
const EUpgradeCapInvalid: u64 = 5;
const ENotNewOwner: u64 = 6;
const EReceiverLen: u64 = 7;
const EInvalidSendContext: u64 = 8;

// === Constants ===
const VERSION: u64 = 1;

/// Message type for basic token transfers
const SEND_TOKEN_TYPE: u16 = 1;
const SEND_MINT_BUDGET_TYPE: u16 = 2;

// === Events ===

public struct TransferOwnershipEvent has copy, drop {
    old_owner: address,
    new_owner: address,
    req_id: ID,
}

public struct CCReceiveEvent has copy, drop {
    guid: Bytes32, // Unique identifier for this cross-chain message, used for tracking and correlation
    src_eid: u32, // Source endpoint ID where tokens are being sent
    msg_data: vector<u8>,
}

public struct CCSendTokenEvent has copy, drop {
    guid: Bytes32, // Unique identifier for this cross-chain message, used for tracking and correlation
    dst_eid: u32, // Destination endpoint ID where tokens are being sent
    msg_data: vector<u8>,
}

public struct CCSendMintBudgetEvent has copy, drop {
    guid: Bytes32, // Unique identifier for this cross-chain message, used for tracking and correlation
    dst_eid: u32, // Destination endpoint ID where tokens are being sent
    msg_data: vector<u8>,
}

// === Structs ===

// OTW
public struct MESSENGER_OAPP has drop {}

public struct TransferOwnershipReq has key {
    id: UID,
    new_owner: address,
    upgrade_cap: UpgradeCap,
}

// Core struct containing all configuration and state.
public struct State has key {
    id: UID,
    version: u64,
    oapp_call_cap: CallCap,
    oapp_admin_cap: AdminCap,
    mtoken_msg_cap: Option<MessengerCap>,
    upgrade_cap_id: Option<ID>,
    eid_to_addr_len: Table<u32, u8>,
    owner: address,
    paused: bool,
}

public struct SendContext {
    is_token: bool,
    msg_data: vector<u8>,
    call_id: address,
}

// https://docs.layerzero.network/v2/developers/sui/oapp/overview#initialization-creating-your-oapp
fun init(otw: MESSENGER_OAPP, ctx: &mut TxContext) {
    let (oapp_call_cap, oapp_admin_cap, _oapp_addr) = oapp::new(&otw, ctx);
    let state = State {
        id: object::new(ctx),
        version: VERSION,
        oapp_call_cap,
        oapp_admin_cap,
        mtoken_msg_cap: option::none(),
        upgrade_cap_id: option::none(),
        eid_to_addr_len: table::new<u32, u8>(ctx),
        owner: ctx.sender(),
        paused: false,
    };
    transfer::share_object(state);
}

// === Admin(Owner) Functions ===

entry fun init_messenger_cap(state: &mut State, mtoken_msg_cap: MessengerCap, ctx: &TxContext) {
    state.check_owner(ctx);
    state.mtoken_msg_cap.fill(mtoken_msg_cap);
}

entry fun init_upgrade_cap_id(state: &mut State, upgrade_cap: &UpgradeCap, ctx: &TxContext) {
    state.check_owner(ctx);
    let package_addr = state.package_address();
    assert!(upgrade_cap.package().to_address() == package_addr, EUpgradeCapInvalid);
    state.upgrade_cap_id.fill(object::id(upgrade_cap));
}

entry fun migrate(state: &mut State, ctx: &TxContext) {
    check_owner(state, ctx);
    assert!(state.version < VERSION, EWrongVersion);
    state.version = VERSION;
}

// step 1 of the ownership transfer process
entry fun request_transfer_ownership(
    state: &State,
    new_owner: address,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    assert!(state.upgrade_cap_id.contains(&object::id(&upgrade_cap)), EUpgradeCapInvalid);

    let id = object::new(ctx);
    let req = TransferOwnershipReq { id, new_owner, upgrade_cap };
    transfer::share_object(req);
}

// step 2 of the ownership transfer process
entry fun execute_transfer_ownership(
    state: &mut State,
    req: TransferOwnershipReq,
    ctx: &TxContext,
) {
    state.check_version();
    assert!(ctx.sender() == req.new_owner, ENotNewOwner);
    let old_owner = state.owner;
    let req_id = object::id(&req);
    let TransferOwnershipReq { id, new_owner, upgrade_cap } = req;

    transfer::public_transfer(upgrade_cap, new_owner);
    state.owner = new_owner;
    id.delete();
    event::emit(TransferOwnershipEvent { old_owner, new_owner, req_id });
}

// cancel the ownership transfer
entry fun revoke_transfer_ownership(state: &State, req: TransferOwnershipReq, ctx: &TxContext) {
    state.check_version();
    state.check_owner(ctx);
    let TransferOwnershipReq { id, upgrade_cap, .. } = req;
    transfer::public_transfer(upgrade_cap, state.owner);
    id.delete();
}

// https://docs.layerzero.network/v2/developers/sui/oapp/overview#registration-connecting-to-the-endpoint
entry fun register_oapp(
    state: &State,
    my_oapp: &OApp,
    endpoint: &mut EndpointV2,
    lz_receive_info: vector<u8>,
    ctx: &mut TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    my_oapp.assert_oapp_cap(&state.oapp_call_cap);
    let oapp_info = oapp_info_v1::create(
        object::id_address(my_oapp), // oapp_object
        vector[], // next_nonce_info
        lz_receive_info,
        vector[], // TODO: extra_info
    );
    let _msg_channel_addr = endpoint_calls::register_oapp(
        my_oapp,
        &state.oapp_admin_cap,
        endpoint,
        oapp_info.encode(),
        ctx,
    );
}

// https://docs.layerzero.network/v2/developers/sui/troubleshooting/common-errors#executor-transaction-fails-unusedvaluewithoutdrop
entry fun set_oapp_info(
    state: &State,
    my_oapp: &OApp,
    endpoint: &mut EndpointV2,
    lz_receive_info: vector<u8>,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    endpoint_calls::set_oapp_info(
        my_oapp,
        &state.oapp_admin_cap,
        endpoint,
        lz_receive_info,
    );
}

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/sui/contracts/oapps/oapp/sources/endpoint_calls.move#L152
entry fun skip(
    state: &State,
    my_oapp: &OApp,
    endpoint: &EndpointV2,
    messaging_channel: &mut MessagingChannel,
    src_eid: u32,
    sender: vector<u8>, // must be 32 bytes
    nonce: u64,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    endpoint_calls::skip(
        my_oapp,
        &state.oapp_admin_cap,
        endpoint,
        messaging_channel,
        src_eid,
        bytes32::from_bytes(sender),
        nonce,
    );
}

// https://docs.layerzero.network/v2/developers/sui/oapp/overview#peer-configuration-establishing-trust
entry fun set_peer(
    state: &mut State,
    my_oapp: &mut OApp,
    endpoint: &EndpointV2,
    channel: &mut MessagingChannel,
    eid: u32,
    peer: vector<u8>, // must be 32 bytes
    addr_len: u8,
    ctx: &mut TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    table_ext::upsert!(&mut state.eid_to_addr_len, eid, addr_len);
    my_oapp.set_peer(
        &state.oapp_admin_cap,
        endpoint,
        channel,
        eid,
        bytes32::from_bytes(peer),
        ctx,
    );
}

// https://docs.layerzero.network/v2/concepts/applications/oapp-standard#execution-options-and-enforced-settings
entry fun set_enforced_options(
    state: &State,
    my_oapp: &mut OApp,
    eid: u32,
    msg_type: u16,
    options: vector<u8>,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    my_oapp.set_enforced_options(&state.oapp_admin_cap, eid, msg_type, options);
}

// pause the messenger
entry fun set_paused(state: &mut State, paused: bool, ctx: &TxContext) {
    state.check_version();
    state.check_owner(ctx);
    state.paused = paused;
}

// === Calculate Fees ===

public fun quote_send_mint_budget(
    state: &State,
    my_oapp: &OApp,
    dst_eid: u32,
    options: vector<u8>,
    amount: u64,
    ctx: &mut TxContext,
): Call<QuoteParam, MessagingFee> {
    state.check_version();
    let mst_data = mtoken::msg_of_cc_send_mint_budget(amount);
    my_oapp.quote(
        &state.oapp_call_cap,
        dst_eid,
        mst_data,
        options,
        false, // pay_in_zro,
        ctx,
    )
}

public fun quote_send_token(
    state: &State,
    my_oapp: &OApp,
    dst_eid: u32,
    options: vector<u8>,
    sender: address,
    receiver: vector<u8>,
    amount: u64,
    ctx: &mut TxContext,
): Call<QuoteParam, MessagingFee> {
    state.check_version();
    let mst_data = mtoken::msg_of_cc_send_token(sender, receiver, amount);
    my_oapp.quote(
        &state.oapp_call_cap,
        dst_eid,
        mst_data,
        options,
        false, // pay_in_zro,
        ctx,
    )
}

public fun confirm_quote_send(
    state: &State,
    my_oapp: &OApp,
    call: Call<QuoteParam, MessagingFee>,
): u64 {
    state.check_version();
    let (_param, fee) = my_oapp.confirm_quote(&state.oapp_call_cap, call);
    fee.native_fee()
}

// === Send Functions ===
// https://docs.layerzero.network/v2/developers/sui/oapp/overview#sending-messages-the-call-pattern

public fun send_mint_budget(
    state: &State,
    mt_state: &mut MtState<XAUM>,
    my_oapp: &mut OApp,
    dst_eid: u32,
    extra_options: vector<u8>,
    native_token_fee: Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
): (Call<SendParam, MessagingReceipt>, SendContext) {
    state.check_version();
    state.check_paused();

    let msg_cap = state.borrow_messenger_cap();
    let msg_data = mt_state.cc_send_mint_budget(msg_cap, amount, ctx);
    let options = my_oapp.combine_options(dst_eid, SEND_MINT_BUDGET_TYPE, extra_options);
    let lz_call = my_oapp.lz_send(
        &state.oapp_call_cap,
        dst_eid,
        msg_data,
        options,
        native_token_fee,
        option::none(), // zro_token_fee
        option::some(ctx.sender()),
        ctx,
    );
    let send_ctx = SendContext { is_token: false, msg_data: msg_data, call_id: lz_call.id() };

    (lz_call, send_ctx)
}

public fun send_token(
    state: &State,
    mt_state: &mut MtState<XAUM>,
    my_oapp: &mut OApp,
    dst_eid: u32,
    extra_options: vector<u8>,
    native_token_fee: Coin<SUI>,
    receiver: vector<u8>,
    xaum_token: Coin<XAUM>,
    ctx: &mut TxContext,
): (Call<SendParam, MessagingReceipt>, SendContext) {
    state.check_version();
    state.check_paused();
    state.check_dst_addr(dst_eid, &receiver);

    let msg_cap = state.borrow_messenger_cap();
    let msg_data = mt_state.cc_send_token(msg_cap, ctx.sender(), receiver, xaum_token, ctx);
    let options = my_oapp.combine_options(dst_eid, SEND_TOKEN_TYPE, extra_options);
    let lz_call = my_oapp.lz_send(
        &state.oapp_call_cap,
        dst_eid,
        msg_data,
        options,
        native_token_fee,
        option::none(), // zro_token_fee
        option::some(ctx.sender()),
        ctx,
    );
    let send_ctx = SendContext { is_token: true, msg_data: msg_data, call_id: lz_call.id() };

    (lz_call, send_ctx)
}

public fun confirm_send(
    state: &State,
    my_oapp: &mut OApp,
    lz_call: Call<SendParam, MessagingReceipt>,
    send_ctx: SendContext,
): (MessagingReceipt, Option<Coin<SUI>>) {
    state.check_version();
    // TODO: more checks?

    let SendContext { is_token, msg_data, call_id } = send_ctx;
    assert!(lz_call.id() == call_id, EInvalidSendContext);

    let (param, messaging_receipt) = my_oapp.confirm_lz_send(&state.oapp_call_cap, lz_call);

    // emit events
    if (is_token) {
        event::emit(CCSendTokenEvent {
            guid: messaging_receipt.guid(),
            dst_eid: param.dst_eid(),
            msg_data: msg_data,
        });
    } else {
        event::emit(CCSendMintBudgetEvent {
            guid: messaging_receipt.guid(),
            dst_eid: param.dst_eid(),
            msg_data: msg_data,
        });
    };

    // refund
    let native_token = if (param.refund_address().is_some()) {
        let refund_address = param.refund_address().destroy_some();
        let (native_token, zro_token) = param.destroy();
        ep_utils::transfer_coin(native_token, refund_address);
        zro_token.destroy_none(); // zro_token must be none
        option::none()
    } else {
        let (native_token, zro_token) = param.destroy();
        zro_token.destroy_none(); // zro_token must be none
        option::some(native_token)
    };

    (messaging_receipt, native_token)
}

// === Receive Functions ===

// https://docs.layerzero.network/v2/developers/sui/oapp/overview#receiving-messages-validation-and-processing
public fun lz_receive(
    state: &State,
    mt_state: &mut MtState<XAUM>,
    my_oapp: &OApp,
    call: Call<LzReceiveParam, Void>,
    ctx: &mut TxContext,
) {
    state.check_version();
    // only check paused in the send functions
    // state.check_paused();

    let param = my_oapp.lz_receive(&state.oapp_call_cap, call);

    let (src_eid, _sender, _nonce, guid, msg, _executor, _extra_data, value) = param.destroy();
    value.destroy_none(); // value must be none

    mt_state.cc_receive(state.borrow_messenger_cap(), msg, ctx);
    event::emit(CCReceiveEvent {
        guid,
        src_eid,
        msg_data: msg,
    });
}

// === View Functions ===

public fun owner(state: &State): address {
    state.owner
}

public fun paused(state: &State): bool {
    state.paused
}

public fun version(state: &State): u64 {
    state.version
}

public fun package_address(_state: &State): address {
    address::from_ascii_bytes(type_name::with_original_ids<State>().address_string().as_bytes())
}

public fun upgrade_cap_id(state: &State): Option<ID> {
    state.upgrade_cap_id
}

// === Private Functions ===

fun check_version(state: &State) {
    assert!(state.version == VERSION, EWrongVersion);
}

fun check_paused(state: &State) {
    assert!(!state.paused, EPaused);
}

fun check_owner(state: &State, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner, ENotOwner);
}

fun borrow_messenger_cap(state: &State): &MessengerCap {
    assert!(state.mtoken_msg_cap.is_some(), ENoMessengerCap);
    state.mtoken_msg_cap.borrow()
}

fun check_dst_addr(state: &State, eid: u32, addr: &vector<u8>) {
    let dst_addr_len = (*state.eid_to_addr_len.borrow(eid)) as u64;
    if (dst_addr_len != 0) {
        assert!(addr.length() == dst_addr_len, EReceiverLen);
    }
}

// === Test Functions ===

#[test_only]
public(package) fun init_for_testing(ctx: &mut TxContext) {
    init(MESSENGER_OAPP {}, ctx);
}

#[test_only]
public(package) fun call_cap(state: &State): &CallCap {
    &state.oapp_call_cap
}

#[test_only]
public(package) fun set_version(state: &mut State, version: u64) {
    state.version = version;
}
