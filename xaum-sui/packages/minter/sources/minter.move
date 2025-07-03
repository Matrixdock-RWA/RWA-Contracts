module minter::minter;

use std::type_name;
use sui::address;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::package::UpgradeCap;
use sui::table;

// === Errors ===
const EWrongVersion: u64 = 100;
const ENotOwner: u64 = 101;
const EUpgradeCapInvalid: u64 = 108;

const EInvalidTokenForMint: u64 = 200;
const EInvalidTokenForRedeem: u64 = 201;
const EInsufficientBalance: u64 = 202;
const EInvalidTimestamp: u64 = 203;

// === Constants ===
const VERSION: u64 = 1;

// const PREPRICE_DECIMAL: u8 = 6; // 6 decimal places for preprice
// const SLIPPAGE_DECIMAL: u8 = 6; // 6 decimal places for slippage
const DELAY_MAX: u64 = 59; // 59 seconds, max delay for requests

// === Events ===

public struct TransferOwnership has copy, drop {
    old_owner: address,
    new_owner: address,
}

public struct SetPoolAccountA has copy, drop {
    pool_account_a: address,
}

public struct SetPoolAccountB has copy, drop {
    pool_account_b: address,
}

public struct SetAcceptedByA has copy, drop {
    token: address,
    accepted: bool,
}

public struct SetAcceptedByB has copy, drop {
    token: address,
    accepted: bool,
}

public struct MintRequest has copy, drop {
    transferred_token: address,
    for_token: address,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
}

public struct RedeemRequest has copy, drop {
    transferred_token: address,
    for_token: address,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
}

// === Structs ===

public struct State has key {
    id: UID,
    version: u64,
    owner: address,
    pool_account_a: address, //stable coin pool
    pool_account_b: address, //rwa pool
    accepted_by_a: table::Table<address, bool>,
    accepted_by_b: table::Table<address, bool>,
}

// === Initialization ===
fun init(ctx: &mut TxContext) {
    let owner = ctx.sender();
    let state = State {
        id: object::new(ctx),
        version: VERSION,
        owner,
        pool_account_a: owner,
        pool_account_b: owner,
        accepted_by_a: table::new<address, bool>(ctx),
        accepted_by_b: table::new<address, bool>(ctx),
    };
    transfer::share_object(state);
}

// === Owner Functions ===

entry fun transfer_ownership(
    state: &mut State,
    new_owner: address,
    upgrade_cap: UpgradeCap,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    let old_owner = state.owner;
    // transfer UpgradeCap !
    assert!(upgrade_cap.package().to_address() == state.package_address(), EUpgradeCapInvalid);
    transfer::public_transfer(upgrade_cap, new_owner);

    state.owner = new_owner;
    event::emit(TransferOwnership { old_owner, new_owner });
}

entry fun migrate(state: &mut State, ctx: &TxContext) {
    check_owner(state, ctx);
    assert!(state.version < VERSION, EWrongVersion);
    state.version = VERSION;
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

entry fun set_accepted_by_a(state: &mut State, token: address, accepted: bool, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
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

entry fun set_accepted_by_b(state: &mut State, token: address, accepted: bool, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
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

public entry fun request_to_mint<T>(
    state: &State,
    transferred_token: &mut Coin<T>,
    for_token: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    let ta = address::from_ascii_bytes(type_name::get<T>().get_address().as_bytes());
    assert!(state.accepted_by_a.contains(ta), EInvalidTokenForMint);
    let now = clock.timestamp_ms() / 1000;
    assert!(now <= timestamp + DELAY_MAX, EInvalidTimestamp);
    let balance = transferred_token.value();
    assert!(balance >= amount, EInsufficientBalance);
    let out = coin::split<T>(transferred_token, amount, ctx);
    transfer::public_transfer(out, state.pool_account_a);
    event::emit(MintRequest {
        transferred_token: ta,
        for_token,
        requestor: ctx.sender(),
        pool: state.pool_account_a,
        amount,
        preprice,
        slippage,
    });
}

public entry fun request_to_redeem<T>(
    state: &State,
    transferred_token: &mut Coin<T>,
    for_token: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
    timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(state);
    let ta = address::from_ascii_bytes(type_name::get<T>().get_address().as_bytes());
    assert!(state.accepted_by_b.contains(ta), EInvalidTokenForRedeem);
    let now = clock.timestamp_ms() / 1000;
    assert!(now <= timestamp + DELAY_MAX, EInvalidTimestamp);
    let balance = transferred_token.value();
    assert!(balance >= amount, EInsufficientBalance);
    let out = coin::split(transferred_token, amount, ctx);
    transfer::public_transfer(out, state.pool_account_b);
    event::emit(RedeemRequest {
        transferred_token: ta,
        for_token,
        requestor: ctx.sender(),
        pool: state.pool_account_b,
        amount,
        preprice,
        slippage,
    });
}

// === View Functions ===

public fun version(state: &State): u64 {
    state.version
}

public fun owner(state: &State): address {
    state.owner
}

public fun pool_account_a(state: &State): address {
    state.pool_account_a
}

public fun pool_account_b(state: &State): address {
    state.pool_account_b
}

public fun accepted_by_a(state: &State, token: address): bool {
    state.accepted_by_a.contains(token)
}

public fun accepted_by_b(state: &State, token: address): bool {
    state.accepted_by_b.contains(token)
}

public fun package_address(_state: &State): address {
    address::from_ascii_bytes(type_name::get_with_original_ids<State>().get_address().as_bytes())
}

// === Private Functions ===

fun check_version(state: &State) {
    assert!(state.version == VERSION, EWrongVersion);
}

fun check_owner(state: &State, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner, ENotOwner);
}

#[test_only]
public(package) fun create_minter(ctx: &mut TxContext) {
    init(ctx)
}

// === Test Functions ===

#[test_only]
public(package) fun new_mint_request_event(
    transferred_token: address,
    for_token: address,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
): MintRequest {
    MintRequest { transferred_token, for_token, requestor, pool, amount, preprice, slippage }
}

#[test_only]
public(package) fun new_redeem_request_event(
    transferred_token: address,
    for_token: address,
    requestor: address,
    pool: address,
    amount: u64,
    preprice: u64,
    slippage: u64,
): RedeemRequest {
    RedeemRequest { transferred_token, for_token, requestor, pool, amount, preprice, slippage }
}
