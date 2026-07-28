// https://docs.sui.io/concepts/sui-move-concepts/conventions
module mtoken::mtoken;

use mtoken::message_codec;
use mtoken::mtoken_rate_limiter::{Self, MTokenRateLimiter};
use std::ascii;
use std::string;
use std::type_name;
use sui::address;
use sui::clock::Clock;
use sui::coin::{Self, TreasuryCap, DenyCapV2, Coin, CoinMetadata};
use sui::deny_list::DenyList;
use sui::dynamic_field as df;
use sui::dynamic_object_field as dof;
use sui::event;
use sui::package::UpgradeCap;
use sui::table::{Self, Table};
use sui::url::Url;

// === Errors ===
const EWrongVersion: u64 = 100;
const ENotOwner: u64 = 101;
const ENotOperator: u64 = 102;
const ENotOwnerOrRevoker: u64 = 103;
const ENotEffective: u64 = 104;
const EMintBudgetNotEnough: u64 = 106;
const ENotNewOwner: u64 = 107;
const EUpgradeCapInvalid: u64 = 108;
const EReqExpired: u64 = 109;
const EUpgradeCapIdNotNone: u64 = 110;
const EInvalidMessageType: u64 = 111;
const EInvalidMessengerCap: u64 = 112;
const EZeroValue: u64 = 115;
const EStateIdMismatch: u64 = 116;
const EAnnualFeeRateTooLarge: u64 = 201;
const EAnnualFeeRateAlreadyInitialized: u64 = 202;
const EAnnualFeeRateNotInitialized: u64 = 203;
const EOzPerTokenBaseTooLarge: u64 = 204;
const EUnexpectedOzPerToken: u64 = 205;
const EPendingMsgsExist: u64 = 117;
const EDeprecated: u64 = 118;
const ERequestArgsMismatch: u64 = 119;
const ENotOwnerOrOperator: u64 = 120;
const ECCSendDisabled: u64 = 121;
const ERateLimitedMsgNotFound: u64 = 122;

// === Constants ===

const VERSION: u64 = 4;

const REQ_TTL: u64 = 3600 * 12; // 12 hours, time to live after effective
const MIN_GOV_DELAY: u64 = 3600 * 24; // 1 day

// must stay in sync with mtoken_gov (constants are module-private in Move)
const OP_UNPAUSE: u256 = 10;
const OP_ENABLE_CC_SEND: u256 = 11;

// Operator-initiated (unlike the OP_* constants above), no mtoken_gov counterpart needed.
// Packed with msg_id (via left-shift) into ensure_delay's req_id so each queued message
// gets its own independent pending-request slot instead of sharing one across all msg_ids.
const OP_CC_PROCESS_RATE_LIMITED_MSG: u256 = 12;
const OP_CC_DISCARD_RATE_LIMITED_MSG: u256 = 13;

const SECONDS_PER_DAY: u64 = 24 * 3600; // ozPerTokenBaseTime are rounded to daily boundary
const DAYS_PER_YEAR: u64 = 365; // dailyFeeRate is annualFeeRate / DAYS_PER_YEAR
const FEE_RATE_BASE: u64 = 1000000000; // feeRate is 9 decimals
const OZ_RATIO_BASE: u64 = 1000000000; // ozPerToken is 9 decimals
const MAX_ANNUAL_FEE_RATE: u64 = FEE_RATE_BASE / 10; // 10%

// === Events ===

public struct TransferOwnershipEvent has copy, drop {
    old_owner: address,
    new_owner: address,
    et: u64,
    req_id: ID,
}

// not used
// Structs are part of a module's public interface and cannot be removed or changed during a 'compatible' upgrade.
#[allow(unused_field)]
public struct SetOperatorEvent has copy, drop {
    old_operator: address,
    new_operator: address,
    et: u64,
    req_id: ID,
}

// not used
public struct SetRevokerEvent has copy, drop {
    old_revoker: address,
    new_revoker: address,
    et: u64,
    req_id: ID,
}

// not used
public struct SetDelayEvent has copy, drop {
    old_delay: u64,
    new_delay: u64,
    et: u64,
    req_id: ID,
}

public struct MintEvent has copy, drop {
    to_address: address,
    amount: u64,
    et: u64,
    req_id: ID,
}

public struct RedeemEvent has copy, drop {
    from_address: address,
    amount: u64,
}

public struct BlockEvent has copy, drop {
    user_address: address,
}

public struct UnblockEvent has copy, drop {
    user_address: address,
}

public struct UpdateAnnualFeeRateEvent has copy, drop {
    annual_fee_rate: u64,
    oz_per_token_base: u64,
    oz_per_token_base_time: u64,
}

public struct UpdateOzPerTokenBaseEvent has copy, drop {
    oz_per_token_base: u64,
    oz_per_token_base_time: u64,
}

public struct CCSendMintBudgetManuallyEvent has copy, drop {
    amount: u64,
}

public struct CCReceiveMintBudgetManuallyEvent has copy, drop {
    amount: u64,
}

public struct CCReceiveMintBudgetEvent has copy, drop {
    amount: u64,
}

public struct CCReceiveTokenEvent has copy, drop {
    sender: vector<u8>,
    receiver: address,
    amount: u64,
}

public struct CCBlockedTokenEvent has copy, drop {
    sender: vector<u8>,
    receiver: address,
    amount: u64,
}

public struct CCSendMintBudgetEvent has copy, drop {
    amount: u64,
}

public struct CCSendTokenEvent has copy, drop {
    sender: address,
    receiver: vector<u8>,
    amount: u64,
}

public struct AddRateLimiterEvent has copy, drop {}

public struct ProcessRateLimitedMsgRequestEvent has copy, drop {
    msg_id: u64,
    et: u64,
}

public struct ProcessRateLimitedMsgEffectedEvent has copy, drop {
    msg_id: u64,
}

public struct DiscardRateLimitedMsgRequestEvent has copy, drop {
    msg_id: u64,
    et: u64,
}

public struct DiscardRateLimitedMsgEffectedEvent has copy, drop {
    msg_id: u64,
}

public struct PausedEvent has copy, drop {
    caller: address,
}

public struct UnpausedEvent has copy, drop {
    caller: address,
}

public struct RequestRevokedEvent has copy, drop {
    req_id: u256,
}

public struct DisableCCSendEvent has copy, drop {}

// === Structs ===

public struct TransferOwnershipReq has key {
    id: UID,
    new_owner: address,
    upgrade_cap: UpgradeCap,
    et: u64,
}

// not used
public struct SetOperatorReq has key {
    id: UID,
    new_operator: address,
    et: u64,
}

// not used
public struct SetRevokerReq has key {
    id: UID,
    new_revoker: address,
    et: u64,
}

// not used
public struct SetDelayReq has key {
    id: UID,
    new_delay: u64,
    et: u64,
}

public struct MintReq has key {
    id: UID,
    recipient: address,
    amount: u64,
    expected_oz_per_token: u64,
    et: u64,
}

// df & dof keys
public struct TreasuryCapKey() has copy, drop, store;
public struct DenyCapKey() has copy, drop, store;
public struct MessengerCapKey() has copy, drop, store;
public struct StateIdKey() has copy, drop, store;
public struct RateLimiterKey() has copy, drop, store;
public struct GovDelayKey() has copy, drop, store;
public struct RequestsKey() has copy, drop, store;
public struct CCSendDisabledKey() has copy, drop, store;

// The state of the MToken contract.
// The type parameter T is unused here but preserved for backward compatibility.
public struct State<phantom T> has key, store {
    id: UID,
    version: u64,
    upgrade_cap_id: Option<ID>,
    owner: address,
    operator: address,
    revoker: address,
    delay: u64,
    mint_budget: u64,
    oz_per_token_base_time: u64, // timestamp of the update of annualFeeRate & ozPerTokenBase, rounded to daily boundary
    oz_per_token_base: u64, // calculated when annualFeeRate is updated, 9 decimals
    annual_fee_rate: u64, // the annual fee rate, 9 decimals
}

// The Capability to communicate with the Messenger contract.
public struct MessengerCap has key, store {
    id: UID,
}

public struct RequestInfo has drop, store {
    effective_time: u64,
    new_value: u256,
}

/*

 Operation                         | Initiator  | Timelock | Revoker        | Executor
-----------------------------------+------------+----------+----------------+-----------
transfer_ownership                 | Owner      | govDelay | Owner/Revoker  | NewOwner
set_gov_delay                      | Owner      | govDelay | Owner/Revoker  | Initiator
set_delay                          | Owner      | govDelay | Owner/Revoker  | Initiator
new_messenger_cap                  | Owner      | govDelay | Owner/Revoker  | Initiator
remove_rate_limiter                | Owner      | govDelay | Owner/Revoker  | Initiator
add_to_rate_limiter_whitelist      | Owner      | govDelay | Owner/Revoker  | Initiator
set_revoker                        | Owner      | govDelay | Owner/Operator | NewRevoker
set_operator                       | Owner      | delay    | Owner/Revoker  | Initiator
set_rate_limit                     | Owner      | delay    | Owner/Revoker  | Initiator
set_single_msg_limit               | Owner      | delay    | Owner/Revoker  | Initiator
unpause                            | Owner      | delay    | Owner/Revoker  | Initiator
enable_cc_send                     | Owner      | delay    | Owner/Revoker  | Initiator
init_upgrade_cap_id                | Owner      | no       | no             | no
migrate                            | Owner      | no       | no             | no
update_description                 | Owner      | no       | no             | no
update_icon_url                    | Owner      | no       | no             | no
add_rate_limiter                   | Owner      | no       | no             | no
remove_from_rate_limiter_whitelist | Owner      | no       | no             | no
init_annual_fee_rate               | Owner      | no       | no             | no
update_annual_fee_rate             | Owner      | no       | no             | no
update_oz_per_token_base           | Owner      | no       | no             | no
mint_to                            | Operator   | delay    | Owner/Revoker  | Initiator
cc_process_rate_limited_msg        | Operator   | delay    | Owner/Revoker  | Initiator
cc_discard_rate_limited_msg        | Operator   | delay    | Owner/Revoker  | Initiator
redeem                             | Operator   | no       | no             | no
cc_send_mint_budget_manually       | Operator   | no       | no             | no
cc_receive_mint_budget_manually    | Operator   | no       | no             | no
pause                              | Operator   | no       | no             | no
disable_cc_send                    | Operator   | no       | no             | no
add_to_blocked_list                | Operator   | no       | no             | no
remove_from_blocked_list           | Operator   | no       | no             | no
cc_send_mint_budget                | Messenger  | no       | no             | no
cc_send_token                      | Messenger  | no       | no             | no
cc_receive                         | Messenger  | no       | no             | no

*/

// === Public & Entry Functions ===
// Note: Functions initiated by the owner that have delayed execution
// (except transfer_ownership) reside in mtoken_gov.move

#[allow(lint(share_owned), deprecated_usage)]
public fun create_coin<T: drop>(
    witness: T,
    decimals: u8,
    symbol: vector<u8>,
    name: vector<u8>,
    description: vector<u8>,
    icon_url: Option<Url>,
    allow_global_pause: bool,
    init_delay: u64,
    ctx: &mut TxContext,
) {
    // https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/docs/sui/coin.md#sui_coin_create_regulated_currency_v2
    let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
        witness,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        allow_global_pause,
        ctx,
    );

    let owner = ctx.sender();
    let mut state = State<T> {
        id: object::new(ctx),
        version: VERSION,
        upgrade_cap_id: option::none(),
        owner: owner,
        operator: owner,
        revoker: owner,
        delay: init_delay,
        mint_budget: 0,
        oz_per_token_base_time: 0, // will be set by init_annual_fee_rate
        oz_per_token_base: 0, // will be set by init_annual_fee_rate
        annual_fee_rate: 0, // will be set by init_annual_fee_rate
    };
    df::add(&mut state.id, GovDelayKey(), init_delay);
    df::add(&mut state.id, CCSendDisabledKey(), false);
    dof::add(&mut state.id, TreasuryCapKey(), treasury_cap);
    dof::add(&mut state.id, DenyCapKey(), deny_cap);
    state.init_requests(ctx);

    // https://docs.sui.io/concepts/object-ownership/shared
    transfer::public_share_object(metadata);
    transfer::public_share_object(state);
}

// can be called only once
entry fun init_annual_fee_rate<T>(
    state: &mut State<T>,
    annual_fee_rate: u64,
    oz_per_token_base: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_owner(state, ctx);
    check_annual_fee_rate(annual_fee_rate);
    assert!(oz_per_token_base <= OZ_RATIO_BASE, EOzPerTokenBaseTooLarge);
    assert!(state.oz_per_token_base_time == 0, EAnnualFeeRateAlreadyInitialized);

    state.oz_per_token_base_time = current_day_start_time(clock);
    state.oz_per_token_base = oz_per_token_base;
    state.annual_fee_rate = annual_fee_rate;
}

entry fun init_upgrade_cap_id<T>(state: &mut State<T>, upgrade_cap: &UpgradeCap, ctx: &TxContext) {
    check_owner(state, ctx);
    assert!(state.upgrade_cap_id.is_none(), EUpgradeCapIdNotNone);
    assert!(upgrade_cap.package().to_address() == state.package_address(), EUpgradeCapInvalid);
    state.upgrade_cap_id = option::some(object::id(upgrade_cap));
}

entry fun migrate<T>(state: &mut State<T>, ctx: &mut TxContext) {
    check_owner(state, ctx);
    assert!(state.version < VERSION, EWrongVersion);
    if (!df::exists(&state.id, GovDelayKey())) {
        df::add(&mut state.id, GovDelayKey(), MIN_GOV_DELAY);
    };
    if (!df::exists(&state.id, CCSendDisabledKey())) {
        df::add(&mut state.id, CCSendDisabledKey(), false);
    };
    state.init_requests(ctx);
    state.version = VERSION;
}

entry fun update_description<T>(
    state: &State<T>,
    metadata: &mut CoinMetadata<T>,
    new_description: string::String,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    coin::update_description(state.borrow_treasury_cap(), metadata, new_description);
}

entry fun update_icon_url<T>(
    state: &State<T>,
    metadata: &mut CoinMetadata<T>,
    new_url: ascii::String,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    coin::update_icon_url(state.borrow_treasury_cap(), metadata, new_url);
}

// add a rate limiter to the state; takes effect without delay.
entry fun add_rate_limiter<T>(
    state: &mut State<T>,
    amount: u64, // initial rate limit amount
    window_seconds: u64, // initial window size in seconds
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    let key = RateLimiterKey();
    let mut rl = mtoken_rate_limiter::create(ctx);
    rl.set_rate_limit(amount, window_seconds, clock);
    df::add(&mut state.id, key, rl);
    event::emit(AddRateLimiterEvent {});
}

// immediately removes a (sender, receiver) pair from the rate limiter whitelist;
// takes effect without delay.
entry fun remove_from_rate_limiter_whitelist<T>(
    state: &mut State<T>,
    sender: vector<u8>,
    receiver: address,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    let rl = state.borrow_rate_limiter_mut();
    rl.update_whitelist(sender, receiver, false);
}

entry fun pause<T>(state: &mut State<T>, deny_list: &mut DenyList, ctx: &mut TxContext) {
    check_version(state);
    check_operator(state, ctx);
    // clear any pending unpause request so it cannot outlive this pause:
    // a request pre-planted (or matured during a previous pause) must not
    // be executable right after a new emergency pause, which would bypass
    // the unpause delay window entirely
    revoke_request(state, OP_UNPAUSE);
    coin::deny_list_v2_enable_global_pause<T>(deny_list, state.borrow_deny_cap_mut(), ctx);
    event::emit(PausedEvent { caller: ctx.sender() });
}

entry fun request_transfer_ownership<T>(
    state: &State<T>,
    new_owner: address,
    upgrade_cap: UpgradeCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    assert!(state.upgrade_cap_id.contains(&object::id(&upgrade_cap)), EUpgradeCapInvalid);

    let old_owner = state.owner;
    let et = get_gov_effective_time(state, clock);
    let id = object::new(ctx);
    let mut req = TransferOwnershipReq { id, new_owner, upgrade_cap, et };
    df::add(&mut req.id, StateIdKey(), object::id(state));

    event::emit(TransferOwnershipEvent { old_owner, new_owner, et, req_id: object::id(&req) });
    transfer::share_object(req);
}

entry fun execute_transfer_ownership<T>(
    state: &mut State<T>,
    req: TransferOwnershipReq,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_version(state);
    check_req(state, &req.id);
    assert!(ctx.sender() == req.new_owner, ENotNewOwner);
    let old_owner = state.owner;
    let req_id = object::id(&req);
    let TransferOwnershipReq { id, new_owner, upgrade_cap, et } = req;
    check_effective_time(clock, et);

    transfer::public_transfer(upgrade_cap, new_owner);
    state.owner = new_owner;
    id.delete();
    event::emit(TransferOwnershipEvent { old_owner, new_owner, et: 0, req_id });
}

entry fun revoke_transfer_ownership<T>(
    state: &State<T>,
    req: TransferOwnershipReq,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner_or_revoker(state, ctx);
    check_req(state, &req.id);
    let TransferOwnershipReq { id, upgrade_cap, .. } = req;
    transfer::public_transfer(upgrade_cap, state.owner);
    id.delete();
}

entry fun update_oz_per_token_base<T>(
    state: &mut State<T>,
    oz_per_token_base: u64,
    oz_per_token_base_time: u64,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    assert!(oz_per_token_base <= OZ_RATIO_BASE, EOzPerTokenBaseTooLarge);
    state.oz_per_token_base = oz_per_token_base;
    state.oz_per_token_base_time = oz_per_token_base_time;
    event::emit(UpdateOzPerTokenBaseEvent {
        oz_per_token_base,
        oz_per_token_base_time,
    });
}

entry fun update_annual_fee_rate<T>(
    state: &mut State<T>,
    annual_fee_rate: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    check_annual_fee_rate(annual_fee_rate);
    assert!(state.oz_per_token_base_time > 0, EAnnualFeeRateNotInitialized);

    let oz_per_token_base = state.oz_per_token(clock);
    let oz_per_token_base_time = current_day_start_time(clock);

    state.annual_fee_rate = annual_fee_rate;
    state.oz_per_token_base = oz_per_token_base;
    state.oz_per_token_base_time = oz_per_token_base_time;
    event::emit(UpdateAnnualFeeRateEvent {
        annual_fee_rate,
        oz_per_token_base,
        oz_per_token_base_time,
    });
}
// https://docs.sui.io/references/framework/sui-framework/coin#function-mint
// https://docs.sui.io/references/framework/sui-framework/coin#0x2_coin_mint_and_transfer

entry fun request_mint_to<T>(
    state: &State<T>,
    recipient: address,
    amount: u64,
    expected_oz_per_token: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    check_oz_per_token(state, expected_oz_per_token, clock);
    let et = get_effective_time(state, clock);
    let mut req = MintReq { id: object::new(ctx), recipient, amount, expected_oz_per_token, et };
    df::add(&mut req.id, StateIdKey(), object::id(state));
    let req_id = object::id(&req);

    transfer::share_object(req);
    event::emit(MintEvent { to_address: recipient, amount, et, req_id });
}

entry fun execute_mint_to<T>(
    state: &mut State<T>,
    req: MintReq,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    check_req(state, &req.id);

    let req_id = object::id(&req);
    let MintReq { id, recipient, amount, expected_oz_per_token, et } = req;
    check_effective_time(clock, et);
    check_oz_per_token(state, expected_oz_per_token, clock);

    deduct_mint_budget(state, amount);

    let minted_coin = coin::mint<T>(state.borrow_treasury_cap_mut(), amount, ctx);
    transfer::public_transfer(minted_coin, recipient);
    id.delete();
    event::emit(MintEvent { to_address: recipient, amount, et: 0, req_id });
}

entry fun revoke_mint_to<T>(state: &State<T>, req: MintReq, ctx: &TxContext) {
    check_version(state);
    check_owner_or_revoker(state, ctx);
    check_req(state, &req.id);
    let MintReq { id, .. } = req;
    id.delete();
}

// https://docs.sui.io/references/framework/sui-framework/coin#0x2_coin_burn
entry fun redeem<T>(
    state: &mut State<T>,
    to_be_burnt: Coin<T>,
    expected_oz_per_token: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    check_oz_per_token(state, expected_oz_per_token, clock);
    let from_address = ctx.sender();
    let amount = to_be_burnt.balance().value();
    coin::burn<T>(state.borrow_treasury_cap_mut(), to_be_burnt);
    state.mint_budget = state.mint_budget + amount;
    event::emit(RedeemEvent { from_address, amount });
}

// https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/docs/sui-framework/coin.md#0x2_coin_deny_list_v2_add
entry fun add_to_blocked_list<T>(
    state: &mut State<T>,
    user_address: address,
    deny_list: &mut DenyList,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    coin::deny_list_v2_add(deny_list, state.borrow_deny_cap_mut(), user_address, ctx);
    event::emit(BlockEvent { user_address });
}

// https://docs.sui.io/references/framework/sui-framework/coin#0x2_coin_deny_list_v2_remove
entry fun remove_from_blocked_list<T>(
    state: &mut State<T>,
    user_address: address,
    deny_list: &mut DenyList,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    coin::deny_list_v2_remove(deny_list, state.borrow_deny_cap_mut(), user_address, ctx);
    event::emit(UnblockEvent { user_address });
}

// when cross-chain bridge is not available,
// we can use this function to manually send mint budget
entry fun cc_send_mint_budget_manually<T>(state: &mut State<T>, amount: u64, ctx: &TxContext) {
    check_non_zero(amount);
    check_version(state);
    check_operator(state, ctx);
    deduct_mint_budget(state, amount);
    event::emit(CCSendMintBudgetManuallyEvent { amount });
}

// when cross-chain bridge is not available,
// we can use this function to manually receive mint budget
entry fun cc_receive_mint_budget_manually<T>(state: &mut State<T>, amount: u64, ctx: &TxContext) {
    check_non_zero(amount);
    check_version(state);
    check_operator(state, ctx);
    state.mint_budget = state.mint_budget + amount;
    event::emit(CCReceiveMintBudgetManuallyEvent { amount });
}

public fun cc_send_mint_budget<T>(
    state: &mut State<T>,
    msg_cap: &MessengerCap,
    amount: u64,
    ctx: &mut TxContext,
): vector<u8> {
    check_version(state);
    check_operator(state, ctx);
    check_messenger_cap(state, msg_cap);
    check_non_zero(amount);
    deduct_mint_budget(state, amount);
    event::emit(CCSendMintBudgetEvent { amount });
    msg_of_cc_send_mint_budget(amount)
}

public fun msg_of_cc_send_mint_budget(amount: u64): vector<u8> {
    message_codec::encode_cc_mint_budget_message(amount)
}

public fun cc_send_token<T>(
    state: &mut State<T>,
    msg_cap: &MessengerCap,
    sender: address,
    receiver: vector<u8>,
    token: Coin<T>,
    _ctx: &mut TxContext,
): vector<u8> {
    check_version(state);
    check_messenger_cap(state, msg_cap);
    check_non_zero(token.balance().value());
    assert!(!state.is_cc_send_disabled(), ECCSendDisabled);

    // Note: Burn fails if the owner is in the deny list.
    let amount = token.balance().value();
    coin::burn<T>(state.borrow_treasury_cap_mut(), token);
    event::emit(CCSendTokenEvent { sender, receiver, amount });
    msg_of_cc_send_token(sender, receiver, amount)
}

public fun msg_of_cc_send_token(sender: address, receiver: vector<u8>, amount: u64): vector<u8> {
    message_codec::encode_cc_token_message(sender, receiver, amount)
}

// keep for backward compatibility
public fun cc_receive<T>(
    _state: &mut State<T>,
    _msg_cap: &MessengerCap,
    _msg: vector<u8>,
    _deny_list: &DenyList,
    _ctx: &mut TxContext,
): (address, Option<Coin<T>>) {
    abort EDeprecated // cc_receive is replaced by cc_receive_v2
}

public fun cc_receive_v2<T>(
    state: &mut State<T>,
    msg_cap: &MessengerCap,
    msg: vector<u8>,
    deny_list: &DenyList,
    clock: &Clock,
    ctx: &mut TxContext,
): (address, Option<Coin<T>>) {
    check_version(state);
    check_messenger_cap(state, msg_cap);

    let decoded_msg = message_codec::decode_cc_message(msg);
    if (decoded_msg.is_mint_budget()) {
        let amount = decoded_msg.extract_mint_budget();
        state.mint_budget = state.mint_budget + amount;
        event::emit(CCReceiveMintBudgetEvent { amount });
        return (@0x0, option::none())
    };

    // handle token message
    assert!(decoded_msg.is_token(), EInvalidMessageType);
    let (sender, receiver, amount) = decoded_msg.extract_token_info();

    // check rate limit
    let rl_key = RateLimiterKey();
    if (df::exists(&state.id, rl_key)) {
        let rl = state.borrow_rate_limiter_mut();
        if (!rl.try_consume_rate_limit_capacity(sender, receiver, amount, clock)) {
            // message overflowed, enqueued for later processing.
            return (@0x0, option::none())
        };
    };

    // mint coin
    let minted_coin = coin::mint<T>(state.borrow_treasury_cap_mut(), amount, ctx);
    if (!coin::deny_list_v2_contains_current_epoch<T>(deny_list, receiver, ctx)) {
        transfer::public_transfer(minted_coin, receiver);
        event::emit(CCReceiveTokenEvent { sender, receiver, amount });
        (receiver, option::none())
    } else {
        event::emit(CCBlockedTokenEvent { sender, receiver, amount });
        (receiver, option::some(minted_coin))
    }
}

// request (or, once matured, execute) delivery of a single queued rate-limited cross-chain
// token message; delayed via the normal `delay` (same mechanism as unpause/enable_cc_send)
entry fun cc_process_rate_limited_msg<T>(
    state: &mut State<T>,
    msg_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    // requiring the message to exist at request time stops the operator from pre-registering
    // a request for a not-yet-queued msg_id and letting it mature in advance, so a real message
    // that later lands there gets delivered instantly with no delay ever having applied to it
    assert!(has_rate_limited_msg(state, msg_id), ERateLimitedMsgNotFound);
    let req_id = (OP_CC_PROCESS_RATE_LIMITED_MSG << 64) | (msg_id as u256);
    let et = ensure_delay(state, req_id, 0u256, clock);
    if (et > 0) {
        event::emit(ProcessRateLimitedMsgRequestEvent { msg_id, et });
    } else {
        process_rate_limited_msg(state, msg_id, ctx);
    }
}

entry fun revoke_cc_process_rate_limited_msg<T>(
    state: &mut State<T>,
    msg_id: u64,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner_or_revoker(state, ctx);
    let req_id = (OP_CC_PROCESS_RATE_LIMITED_MSG << 64) | (msg_id as u256);
    revoke_request(state, req_id);
}

// request (or, once matured, execute) permanent discard of a single queued rate-limited
// cross-chain token message; delayed via the normal `delay`
entry fun cc_discard_rate_limited_msg<T>(
    state: &mut State<T>,
    msg_id: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_version(state);
    check_operator(state, ctx);
    // see cc_process_rate_limited_msg for why the message must exist at request time
    assert!(has_rate_limited_msg(state, msg_id), ERateLimitedMsgNotFound);
    let req_id = (OP_CC_DISCARD_RATE_LIMITED_MSG << 64) | (msg_id as u256);
    let et = ensure_delay(state, req_id, 0u256, clock);
    if (et > 0) {
        event::emit(DiscardRateLimitedMsgRequestEvent { msg_id, et });
    } else {
        discard_rate_limited_msg(state, msg_id);
    }
}

entry fun revoke_cc_discard_rate_limited_msg<T>(
    state: &mut State<T>,
    msg_id: u64,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner_or_revoker(state, ctx);
    let req_id = (OP_CC_DISCARD_RATE_LIMITED_MSG << 64) | (msg_id as u256);
    revoke_request(state, req_id);
}

entry fun disable_cc_send<T>(state: &mut State<T>, ctx: &TxContext) {
    check_version(state);
    check_operator(state, ctx);
    // clear any pending enable_cc_send request so it cannot outlive this
    // disable: a request pre-planted (or matured during a previous disable)
    // must not be executable right after a new emergency disable, which
    // would bypass the enable delay window entirely
    revoke_request(state, OP_ENABLE_CC_SEND);
    state.set_cc_send_disabled(true);
    event::emit(DisableCCSendEvent {});
}

// === View Functions ===

public fun version<T>(state: &State<T>): u64 {
    state.version
}

public fun upgrade_cap_id<T>(state: &State<T>): Option<ID> {
    state.upgrade_cap_id
}

public fun owner<T>(state: &State<T>): address {
    state.owner
}

public fun operator<T>(state: &State<T>): address {
    state.operator
}

public fun revoker<T>(state: &State<T>): address {
    state.revoker
}

public fun delay<T>(state: &State<T>): u64 {
    state.delay
}

public fun gov_delay<T>(state: &State<T>): u64 {
    *df::borrow(&state.id, GovDelayKey())
}

public fun is_cc_send_disabled<T>(state: &State<T>): bool {
    *df::borrow(&state.id, CCSendDisabledKey())
}

public fun mint_budget<T>(state: &State<T>): u64 {
    state.mint_budget
}

public fun oz_per_token_base_time<T>(state: &State<T>): u64 {
    state.oz_per_token_base_time
}

public fun annual_fee_rate<T>(state: &State<T>): u64 {
    state.annual_fee_rate
}

public fun oz_per_token_base<T>(state: &State<T>): u64 {
    state.oz_per_token_base
}

public fun package_address<T>(_state: &State<T>): address {
    address::from_ascii_bytes(type_name::with_original_ids<State<T>>().address_string().as_bytes())
}

public fun total_supply<T>(state: &State<T>): u64 {
    coin::total_supply<T>(state.borrow_treasury_cap())
}

// ozPerTokenBase - annualFeeRate*daysElapsed/365
public fun oz_per_token<T>(state: &State<T>, clock: &Clock): u64 {
    assert!(state.oz_per_token_base_time > 0, EAnnualFeeRateNotInitialized);
    let seconds_elapsed = clock.timestamp_ms() / 1000 - state.oz_per_token_base_time;
    let days_elapsed = seconds_elapsed / SECONDS_PER_DAY;
    state.oz_per_token_base - (state.annual_fee_rate * days_elapsed) / DAYS_PER_YEAR
}

// get oz amount from token amount
public fun get_oz_amount<T>(state: &State<T>, token_amount: u64, clock: &Clock): u64 {
    let oz_per_token = state.oz_per_token(clock) as u128;
    ((token_amount as u128 * oz_per_token) / (OZ_RATIO_BASE as u128)) as u64
}

// return true if the rate limiter is set
public fun has_rate_limiter<T>(state: &State<T>): bool {
    df::exists(&state.id, RateLimiterKey())
}

// return the rate limit and window (in seconds)
public fun rate_limit<T>(state: &State<T>): (u64, u64) {
    let rl = state.borrow_rate_limiter();
    rl.get_rate_limit()
}

// return (in_flight, capacity) at the current clock time
public fun amount_can_be_received<T>(state: &State<T>, clock: &Clock): (u64, u64) {
    let rl = state.borrow_rate_limiter();
    rl.amount_can_be_received(clock)
}

// return (sender, receiver, amount) of a queued rate-limited message
public fun rate_limited_msg<T>(state: &State<T>, msg_id: u64): (vector<u8>, address, u64) {
    let rl = state.borrow_rate_limiter();
    rl.rate_limited_msg(msg_id)
}

// return true if the message is queued
public fun has_rate_limited_msg<T>(state: &State<T>, msg_id: u64): bool {
    let rl = state.borrow_rate_limiter();
    rl.has_rate_limited_msg(msg_id)
}

// return the single message limit (0 = disabled)
public fun single_msg_limit<T>(state: &State<T>): u64 {
    let rl = state.borrow_rate_limiter();
    rl.get_single_msg_limit()
}

// return true if the (sender, receiver) pair is whitelisted
public fun is_in_whitelist<T>(state: &State<T>, sender: vector<u8>, receiver: address): bool {
    let rl = state.borrow_rate_limiter();
    rl.is_in_whitelist(sender, receiver)
}

// === Package Functions ===

public(package) fun check_version<T>(state: &State<T>) {
    assert!(state.version == VERSION, EWrongVersion);
}

public(package) fun check_owner<T>(state: &State<T>, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner, ENotOwner);
}

public(package) fun check_owner_or_revoker<T>(state: &State<T>, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner || ctx.sender() == state.revoker, ENotOwnerOrRevoker);
}

public(package) fun check_owner_or_operator<T>(state: &State<T>, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner || ctx.sender() == state.operator, ENotOwnerOrOperator);
}

public(package) fun set_cc_send_disabled<T>(state: &mut State<T>, flag: bool) {
    *df::borrow_mut(&mut state.id, CCSendDisabledKey()) = flag;
}

public(package) fun set_gov_delay<T>(state: &mut State<T>, new_gov_delay: u64) {
    *df::borrow_mut(&mut state.id, GovDelayKey()) = new_gov_delay;
}

public(package) fun set_delay<T>(state: &mut State<T>, new_delay: u64) {
    state.delay = new_delay;
}

public(package) fun set_operator<T>(state: &mut State<T>, new_operator: address) {
    state.operator = new_operator;
}

public(package) fun set_revoker<T>(state: &mut State<T>, new_revoker: address) {
    state.revoker = new_revoker;
}

public(package) fun unpause<T>(
    state: &mut State<T>,
    deny_list: &mut DenyList,
    ctx: &mut TxContext,
) {
    let deny_cap = state.borrow_deny_cap_mut();
    coin::deny_list_v2_disable_global_pause<T>(deny_list, deny_cap, ctx);
    event::emit(UnpausedEvent { caller: ctx.sender() });
}

public(package) fun cc_new_messenger_cap<T>(
    state: &mut State<T>,
    holder: address,
    ctx: &mut TxContext,
) {
    let cap = MessengerCap { id: object::new(ctx) };
    let key = MessengerCapKey();
    df::remove_opt<MessengerCapKey, sui::object::ID>(&mut state.id, key);
    df::add(&mut state.id, key, object::id(&cap));
    transfer::transfer(cap, holder);
}

public(package) fun remove_rate_limiter<T>(state: &mut State<T>) {
    let rl: MTokenRateLimiter = df::remove(&mut state.id, RateLimiterKey());
    assert!(!rl.has_pending_msgs(), EPendingMsgsExist);
    rl.drop();
}

public(package) fun set_rate_limit<T>(
    state: &mut State<T>,
    amount: u64,
    window_seconds: u64,
    clock: &Clock,
) {
    let rl = state.borrow_rate_limiter_mut();
    rl.set_rate_limit(amount, window_seconds, clock);
}

public(package) fun set_single_msg_limit<T>(state: &mut State<T>, limit: u64) {
    let rl = state.borrow_rate_limiter_mut();
    rl.set_single_msg_limit(limit);
}

public(package) fun add_to_rate_limiter_whitelist<T>(
    state: &mut State<T>,
    sender: vector<u8>,
    receiver: address,
) {
    let rl = state.borrow_rate_limiter_mut();
    rl.update_whitelist(sender, receiver, true);
}

public(package) fun ensure_gov_delay<T>(
    state: &mut State<T>,
    req_id: u256,
    new_value: u256,
    clock: &Clock,
): u64 {
    ensure_delay_(state, req_id, new_value, true, clock)
}

public(package) fun ensure_delay<T>(
    state: &mut State<T>,
    req_id: u256,
    new_value: u256,
    clock: &Clock,
): u64 {
    ensure_delay_(state, req_id, new_value, false, clock)
}

public(package) fun revoke_request<T>(state: &mut State<T>, req_id: u256) {
    let requests: &mut Table<u256, RequestInfo> = dof::borrow_mut(
        &mut state.id,
        RequestsKey(),
    );
    if (requests.contains(req_id)) {
        requests.remove(req_id);
        event::emit(RequestRevokedEvent { req_id });
    }
}

// === Private Functions ===

// https://docs.sui.io/references/framework/sui-framework/clock#function-timestamp_ms

fun get_effective_time<T>(state: &State<T>, clock: &Clock): u64 {
    clock.timestamp_ms() / 1000 + state.delay
}

fun get_gov_effective_time<T>(state: &State<T>, clock: &Clock): u64 {
    clock.timestamp_ms() / 1000 + gov_delay(state)
}

fun check_effective_time(clock: &Clock, et: u64) {
    let now = clock.timestamp_ms() / 1000;
    assert!(et <= now, ENotEffective);
    assert!(et + REQ_TTL > now, EReqExpired);
}

fun check_operator<T>(state: &State<T>, ctx: &TxContext) {
    assert!(ctx.sender() == state.operator, ENotOperator);
}

fun check_messenger_cap<T>(state: &State<T>, cap: &MessengerCap) {
    let valid_capId = df::borrow(&state.id, MessengerCapKey());
    let cap_id = object::id(cap);
    assert!(cap_id == valid_capId, EInvalidMessengerCap);
}

fun check_req<T>(state: &State<T>, req_id: &UID) {
    let state_id = df::borrow(req_id, StateIdKey());
    assert!(state_id == object::id(state), EStateIdMismatch);
}

fun check_non_zero(amount: u64) {
    assert!(amount > 0, EZeroValue);
}

// _annualFeeRate can not be greater than MAX_ANNUAL_FEE_RATE
fun check_annual_fee_rate(_annual_fee_rate: u64) {
    assert!(_annual_fee_rate <= MAX_ANNUAL_FEE_RATE, EAnnualFeeRateTooLarge);
}

fun check_oz_per_token<T>(state: &State<T>, expected_oz_per_token: u64, clock: &Clock) {
    let actual_oz_per_token = state.oz_per_token(clock);
    assert!(actual_oz_per_token == expected_oz_per_token, EUnexpectedOzPerToken);
}

fun deduct_mint_budget<T>(state: &mut State<T>, amount: u64) {
    assert!(state.mint_budget >= amount, EMintBudgetNotEnough);
    state.mint_budget = state.mint_budget - amount;
}

fun borrow_treasury_cap<T>(state: &State<T>): &TreasuryCap<T> {
    dof::borrow(&state.id, TreasuryCapKey())
}

fun borrow_treasury_cap_mut<T>(state: &mut State<T>): &mut TreasuryCap<T> {
    dof::borrow_mut(&mut state.id, TreasuryCapKey())
}

fun borrow_deny_cap_mut<T>(state: &mut State<T>): &mut DenyCapV2<T> {
    dof::borrow_mut(&mut state.id, DenyCapKey())
}

// current day start time, rounded to daily boundary
fun current_day_start_time(clock: &Clock): u64 {
    (clock.timestamp_ms() / 1000 / SECONDS_PER_DAY) * SECONDS_PER_DAY
}

fun borrow_rate_limiter<T>(state: &State<T>): &MTokenRateLimiter {
    df::borrow(&state.id, RateLimiterKey())
}

fun borrow_rate_limiter_mut<T>(state: &mut State<T>): &mut MTokenRateLimiter {
    df::borrow_mut(&mut state.id, RateLimiterKey())
}

fun init_requests<T>(state: &mut State<T>, ctx: &mut TxContext) {
    if (!dof::exists(&state.id, RequestsKey())) {
        let requests = table::new<u256, RequestInfo>(ctx);
        dof::add(&mut state.id, RequestsKey(), requests);
    }
}

fun ensure_delay_<T>(
    state: &mut State<T>,
    req_id: u256,
    new_value: u256,
    is_gov: bool,
    clock: &Clock,
): u64 {
    let effective_time = if (is_gov) {
        state.get_gov_effective_time(clock)
    } else {
        state.get_effective_time(clock)
    };

    let requests: &mut Table<u256, RequestInfo> = dof::borrow_mut(
        &mut state.id,
        RequestsKey(),
    );

    if (!requests.contains(req_id)) {
        requests.add(req_id, RequestInfo { effective_time, new_value });
        return effective_time
    };

    let req_info = &requests[req_id];
    check_effective_time(clock, req_info.effective_time);
    assert!(req_info.new_value == new_value, ERequestArgsMismatch);
    requests.remove(req_id);
    return 0
}

// private function to process a single rate-limited message
fun process_rate_limited_msg<T>(state: &mut State<T>, msg_id: u64, ctx: &mut TxContext) {
    let rl = state.borrow_rate_limiter_mut();
    let (sender, receiver, amount) = rl.remove_rate_limited_msg(msg_id);
    let minted_coin = coin::mint<T>(state.borrow_treasury_cap_mut(), amount, ctx);
    transfer::public_transfer(minted_coin, receiver);
    event::emit(CCReceiveTokenEvent { sender, receiver, amount });
    event::emit(ProcessRateLimitedMsgEffectedEvent { msg_id });
    // clear any pending discard request for the same msg_id: once this msg_id is consumed,
    // a stale sibling request must not survive to be matched against a future message that
    // reuses this msg_id after the rate limiter is removed and re-added (see
    // cc_process_rate_limited_msg / cc_discard_rate_limited_msg)
    revoke_request(state, (OP_CC_DISCARD_RATE_LIMITED_MSG << 64) | (msg_id as u256));
}

// private function to discard a single rate-limited message
fun discard_rate_limited_msg<T>(state: &mut State<T>, msg_id: u64) {
    let rl = state.borrow_rate_limiter_mut();
    let (_sender, _receiver, _amount) = rl.remove_rate_limited_msg(msg_id);
    event::emit(DiscardRateLimitedMsgEffectedEvent { msg_id });
    // clear any pending process request for the same msg_id (see process_rate_limited_msg)
    revoke_request(state, (OP_CC_PROCESS_RATE_LIMITED_MSG << 64) | (msg_id as u256));
}

// === Test Functions ===

#[test_only]
public(package) fun set_version<T>(state: &mut State<T>, version: u64) {
    state.version = version;
}

#[test_only]
public(package) fun new_mint_event(
    to_address: address,
    amount: u64,
    et: u64,
    req_id: ID,
): MintEvent {
    MintEvent { to_address, amount, et, req_id }
}

#[test_only]
public(package) fun new_redeem_event(from_address: address, amount: u64): RedeemEvent {
    RedeemEvent { from_address, amount }
}

#[test_only]
public(package) fun new_block_event(user_address: address): BlockEvent {
    BlockEvent { user_address }
}

#[test_only]
public(package) fun new_unblock_event(user_address: address): UnblockEvent {
    UnblockEvent { user_address }
}

#[test_only]
public(package) fun new_update_annual_fee_rate_event(
    annual_fee_rate: u64,
    oz_per_token_base: u64,
    oz_per_token_base_time: u64,
): UpdateAnnualFeeRateEvent {
    UpdateAnnualFeeRateEvent { annual_fee_rate, oz_per_token_base, oz_per_token_base_time }
}

#[test_only]
public(package) fun new_cc_send_mint_budget_manually_event(
    amount: u64,
): CCSendMintBudgetManuallyEvent {
    CCSendMintBudgetManuallyEvent { amount }
}

#[test_only]
public(package) fun new_cc_receive_mint_budget_manually_event(
    amount: u64,
): CCReceiveMintBudgetManuallyEvent {
    CCReceiveMintBudgetManuallyEvent { amount }
}

#[test_only]
public fun set_mint_budget<T>(state: &mut State<T>, val: u64) {
    state.mint_budget = val;
}

#[test_only]
public fun mint_for_testing<T>(state: &mut State<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    state.check_owner(ctx);
    coin::mint<T>(state.borrow_treasury_cap_mut(), amount, ctx)
}
