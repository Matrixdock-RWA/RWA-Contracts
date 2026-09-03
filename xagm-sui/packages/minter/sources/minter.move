module minter::minter;

use std::type_name::{Self, TypeName};
use sui::address;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::package::UpgradeCap;
use sui::table;

// === Errors ===
const EWrongVersion: u64 = 100;
const ENotOwner: u64 = 101;
const EUpgradeCapIdNotNone: u64 = 102;
const ENoOwnerTransferRequest: u64 = 103;
const EOwnerTransferNotReady: u64 = 104;
const ENotNewOwner: u64 = 105;
const EPendingOwnerExist: u64 = 106;
const EUpgradeCapInvalid: u64 = 108;
const EGovDelayTooShort: u64 = 109;
const EGovDelayTooLong: u64 = 110;
const EGovDelayNotReady: u64 = 111;
const EGovDelayArgsMismatch: u64 = 112;

const EInvalidTokenForMint: u64 = 200;
const EInvalidTokenForRedeem: u64 = 201;
const EInsufficientBalance: u64 = 202;
const EInvalidTimestamp: u64 = 203;
const EZeroValue: u64 = 204;

// === Constants ===
const VERSION: u64 = 1;

// const PREPRICE_DECIMAL: u8 = 6; // 6 decimal places for preprice
// const SLIPPAGE_DECIMAL: u8 = 6; // 6 decimal places for slippage
const DELAY_MAX: u64 = 59; // 59 seconds, max delay for requests

// Governance-level timelock bounds. gov_delay guards control-plane
// operations (transfer_ownership, set_gov_delay). It is deliberately initialized to 0
// on a fresh deploy (timelock disarmed) so the deployer can finish wiring and hand over
// ownership without waiting; once armed via set_gov_delay it is bounded to [24h, 7d].
const MIN_GOV_DELAY: u64 = 3600 * 24; // 1 day
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7 days

// === Events ===

public struct TransferOwnershipRequest has copy, drop {
    old_owner: address,
    new_owner: address,
    et: u64,
}

public struct TransferOwnershipEffected has copy, drop {
    old_owner: address,
    new_owner: address,
}

public struct TransferOwnershipRevoked has copy, drop {
    owner: address,
}

public struct SetGovDelayRequest has copy, drop {
    old_gov_delay: u64,
    new_gov_delay: u64,
    et: u64,
}

public struct SetGovDelayEffected has copy, drop {
    new_gov_delay: u64,
}

public struct NextGovDelayRevoked has copy, drop {
    pending_gov_delay: u64,
}

public struct SetPoolAccountA has copy, drop {
    pool_account_a: address,
}

public struct SetPoolAccountB has copy, drop {
    pool_account_b: address,
}

public struct SetAcceptedByA has copy, drop {
    token: TypeName,
    accepted: bool,
}

public struct SetAcceptedByB has copy, drop {
    token: TypeName,
    accepted: bool,
}

public struct MintRequest has copy, drop {
    transferred_token: TypeName,
    for_token: TypeName,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    extra_data: vector<u8>,
}

public struct RedeemRequest has copy, drop {
    transferred_token: TypeName,
    for_token: TypeName,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    extra_data: vector<u8>,
}

// === Structs ===

public struct State has key {
    id: UID,
    version: u64,
    upgrade_cap_id: Option<ID>,
    owner: address,
    next_owner: Option<address>,
    next_owner_et: u64,
    // UpgradeCap escrowed by a pending ownership transfer, released on accept/revoke.
    pending_upgrade_cap: Option<UpgradeCap>,
    gov_delay: u64,
    next_gov_delay: Option<u64>,
    next_gov_delay_et: u64,
    pool_account_a: address, //stable coin pool
    pool_account_b: address, //rwa pool
    accepted_by_a: table::Table<TypeName, bool>,
    accepted_by_b: table::Table<TypeName, bool>,
}

// === Initialization ===
fun init(ctx: &mut TxContext) {
    let owner = ctx.sender();
    let state = State {
        id: object::new(ctx),
        version: VERSION,
        upgrade_cap_id: option::none(),
        owner,
        next_owner: option::none(),
        next_owner_et: 0,
        pending_upgrade_cap: option::none(),
        // gov_delay starts disarmed (0) so the deployer can complete wiring and ownership
        // handover without waiting.
        gov_delay: 0,
        next_gov_delay: option::none(),
        next_gov_delay_et: 0,
        pool_account_a: owner,
        pool_account_b: owner,
        accepted_by_a: table::new<TypeName, bool>(ctx),
        accepted_by_b: table::new<TypeName, bool>(ctx),
    };
    transfer::share_object(state);
}

// === Owner Functions ===

entry fun init_upgrade_cap_id(state: &mut State, upgrade_cap: &UpgradeCap, ctx: &TxContext) {
    check_owner(state, ctx);
    assert!(state.upgrade_cap_id.is_none(), EUpgradeCapIdNotNone);
    assert!(upgrade_cap.package().to_address() == state.package_address(), EUpgradeCapInvalid);
    state.upgrade_cap_id = option::some(object::id(upgrade_cap));
}

entry fun set_gov_delay(state: &mut State, new_gov_delay: u64, clock: &Clock, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    assert!(new_gov_delay >= MIN_GOV_DELAY, EGovDelayTooShort);
    assert!(new_gov_delay <= MAX_GOV_DELAY, EGovDelayTooLong);

    let now = clock.timestamp_ms() / 1000;
    if (state.next_gov_delay_et == 0) {
        let curr_gov_delay = state.gov_delay;
        let et = now + curr_gov_delay;
        state.next_gov_delay = option::some(new_gov_delay);
        state.next_gov_delay_et = et;
        event::emit(SetGovDelayRequest { old_gov_delay: curr_gov_delay, new_gov_delay, et });
    } else {
        assert!(state.next_gov_delay.contains(&new_gov_delay), EGovDelayArgsMismatch);
        assert!(now >= state.next_gov_delay_et, EGovDelayNotReady);
        state.gov_delay = new_gov_delay;
        clear_next_gov_delay(state);
        event::emit(SetGovDelayEffected { new_gov_delay });
    }
}

// Cancel a pending gov_delay change. Immediate and idempotent.
entry fun revoke_set_gov_delay(state: &mut State, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    event::emit(NextGovDelayRevoked { pending_gov_delay: state.next_gov_delay.get_with_default(0) });
    clear_next_gov_delay(state);
}

entry fun request_transfer_ownership(
    state: &mut State,
    new_owner: address,
    upgrade_cap: UpgradeCap,
    clock: &Clock,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    assert!(state.next_owner_et == 0, EPendingOwnerExist);
    assert!(state.upgrade_cap_id.contains(&object::id(&upgrade_cap)), EUpgradeCapInvalid);

    let et = clock.timestamp_ms() / 1000 + state.gov_delay;
    state.next_owner = option::some(new_owner);
    state.next_owner_et = et;
    state.pending_upgrade_cap.fill(upgrade_cap);
    event::emit(TransferOwnershipRequest { old_owner: state.owner, new_owner, et });
}

entry fun accept_transfer_ownership(state: &mut State, clock: &Clock, ctx: &TxContext) {
    check_version(state);
    assert!(state.next_owner.is_some(), ENoOwnerTransferRequest);
    assert!(ctx.sender() == *state.next_owner.borrow(), ENotNewOwner);
    let now = clock.timestamp_ms() / 1000;
    assert!(now >= state.next_owner_et, EOwnerTransferNotReady);

    let new_owner = state.next_owner.extract();
    let old_owner = state.owner;
    state.owner = new_owner;
    state.next_owner_et = 0;
    let upgrade_cap = state.pending_upgrade_cap.extract();
    transfer::public_transfer(upgrade_cap, new_owner);
    event::emit(TransferOwnershipEffected { old_owner, new_owner });
}

entry fun revoke_transfer_ownership(state: &mut State, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    assert!(state.next_owner.is_some(), ENoOwnerTransferRequest);
    state.next_owner = option::none();
    state.next_owner_et = 0;
    let upgrade_cap = state.pending_upgrade_cap.extract();
    transfer::public_transfer(upgrade_cap, state.owner);
    event::emit(TransferOwnershipRevoked { owner: state.owner });
}

entry fun set_pool_account_a(state: &mut State, pool_account_a: address, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    state.pool_account_a = pool_account_a;
    event::emit(SetPoolAccountA { pool_account_a });
}

entry fun set_pool_account_b(state: &mut State, pool_account_b: address, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    state.pool_account_b = pool_account_b;
    event::emit(SetPoolAccountB { pool_account_b });
}

entry fun set_accepted_by_a<T>(state: &mut State, accepted: bool, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let token = type_name::with_defining_ids<T>();
    if (state.accepted_by_a.contains(token)) {
        if (!accepted) {
            state.accepted_by_a.remove(token);
        }
    } else {
        if (accepted) {
            state.accepted_by_a.add(token, true);
        }
    };
    event::emit(SetAcceptedByA { token, accepted });
}

entry fun set_accepted_by_b<T>(state: &mut State, accepted: bool, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let token = type_name::with_defining_ids<T>();
    if (state.accepted_by_b.contains(token)) {
        if (!accepted) {
            state.accepted_by_b.remove(token);
        }
    } else {
        if (accepted) {
            state.accepted_by_b.add(token, true);
        }
    };
    event::emit(SetAcceptedByB { token, accepted });
}

// === Public Functions ===

public fun request_to_mint<T, F>(
    state: &State,
    transferred_token: &mut Coin<T>,
    amount: u64,
    preprice: u64,
    slippage: u64,
    timestamp: u64,
    extra_data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_non_zero(amount);
    let tn = type_name::with_defining_ids<T>();
    assert!(state.accepted_by_a.contains(tn), EInvalidTokenForMint);
    let now = clock.timestamp_ms() / 1000;
    assert!(now <= timestamp + DELAY_MAX, EInvalidTimestamp);
    let balance = transferred_token.value();
    assert!(balance >= amount, EInsufficientBalance);
    let out = coin::split<T>(transferred_token, amount, ctx);
    transfer::public_transfer(out, state.pool_account_a);
    event::emit(MintRequest {
        transferred_token: tn,
        for_token: type_name::with_defining_ids<F>(),
        requestor: ctx.sender(),
        pool: state.pool_account_a,
        amount,
        preprice,
        slippage,
        extra_data,
    });
}

public fun request_to_redeem<T, F>(
    state: &State,
    transferred_token: &mut Coin<T>,
    amount: u64,
    preprice: u64,
    slippage: u64,
    timestamp: u64,
    extra_data: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    check_non_zero(amount);
    let tn = type_name::with_defining_ids<T>();
    assert!(state.accepted_by_b.contains(tn), EInvalidTokenForRedeem);
    let now = clock.timestamp_ms() / 1000;
    assert!(now <= timestamp + DELAY_MAX, EInvalidTimestamp);
    let balance = transferred_token.value();
    assert!(balance >= amount, EInsufficientBalance);
    let out = coin::split(transferred_token, amount, ctx);
    transfer::public_transfer(out, state.pool_account_b);
    event::emit(RedeemRequest {
        transferred_token: tn,
        for_token: type_name::with_defining_ids<F>(),
        requestor: ctx.sender(),
        pool: state.pool_account_b,
        amount,
        preprice,
        slippage,
        extra_data,
    });
}

// === View Functions ===

public fun version(state: &State): u64 {
    state.version
}

public fun upgrade_cap_id(state: &State): Option<ID> {
    state.upgrade_cap_id
}

public fun owner(state: &State): address {
    state.owner
}

public fun next_owner(state: &State): Option<address> {
    state.next_owner
}

public fun next_owner_et(state: &State): u64 {
    state.next_owner_et
}

public fun gov_delay(state: &State): u64 {
    state.gov_delay
}

public fun next_gov_delay(state: &State): Option<u64> {
    state.next_gov_delay
}

public fun next_gov_delay_et(state: &State): u64 {
    state.next_gov_delay_et
}

public fun pool_account_a(state: &State): address {
    state.pool_account_a
}

public fun pool_account_b(state: &State): address {
    state.pool_account_b
}

public fun accepted_by_a(state: &State, token: TypeName): bool {
    state.accepted_by_a.contains(token)
}

public fun accepted_by_b(state: &State, token: TypeName): bool {
    state.accepted_by_b.contains(token)
}

public fun package_address(_state: &State): address {
    address::from_ascii_bytes(type_name::with_original_ids<State>().address_string().as_bytes())
}

// === Private Functions ===

fun check_version(state: &State) {
    assert!(state.version == VERSION, EWrongVersion);
}

fun check_owner(state: &State, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner, ENotOwner);
}

fun check_non_zero(amount: u64) {
    assert!(amount > 0, EZeroValue);
}

fun clear_next_gov_delay(state: &mut State) {
    state.next_gov_delay = option::none();
    state.next_gov_delay_et = 0;
}

// === Test Functions ===

#[test_only]
public(package) fun create_minter(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public(package) fun new_mint_request_event(
    transferred_token: TypeName,
    for_token: TypeName,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    extra_data: vector<u8>,
): MintRequest {
    MintRequest {
        transferred_token,
        for_token,
        requestor,
        pool,
        amount,
        preprice,
        slippage,
        extra_data,
    }
}

#[test_only]
public(package) fun new_redeem_request_event(
    transferred_token: TypeName,
    for_token: TypeName,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    extra_data: vector<u8>,
): RedeemRequest {
    RedeemRequest {
        transferred_token,
        for_token,
        requestor,
        pool,
        amount,
        preprice,
        slippage,
        extra_data,
    }
}

#[test_only]
public(package) fun set_gov_delay_for_testing(state: &mut State, value: u64) {
    state.gov_delay = value;
}
