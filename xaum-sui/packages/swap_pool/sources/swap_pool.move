module swap_pool::swap_pool;

use mmt_v3::i32;
use mmt_v3::i64;
use mmt_v3::pool::{Self, Pool};
use mmt_v3::tick_math;
use pyth::i64 as i64_pyth;
use pyth::price;
use pyth::price_identifier;
use pyth::price_info::{Self, PriceInfoObject};
use pyth::pyth;
use std::type_name::{Self, TypeName};
use std::u64;
use sui::address;
use sui::bag;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::package::UpgradeCap;
use sui::table;
use sui::transfer::Receiving;

// === Errors ===
const EWrongVersion: u64 = 100;
const ENotOwner: u64 = 101;
const ENotOperator: u64 = 102;
const EUpgradeCapInvalid: u64 = 103;
const ECoinNotInWhitelist: u64 = 104;
const EBalanceNotExists: u64 = 105;
const EOraclePriceTooLow: u64 = 106;
const EOraclePriceTooHigh: u64 = 107;
const EInvalidAmountOut: u64 = 108;
const EInvalidAmountIn: u64 = 109;
const EUpgradeCapIdNotNone: u64 = 110;
const EInvalidCoinOutType: u64 = 111;
const EUserNotInWhitelist: u64 = 112;
const EInvalidTickCumulativeLength: u64 = 113;
const EInvalidDexPool: u64 = 114;
const EInvalidOraclePriceId: u64 = 115;

// === Constants ===
const VERSION: u64 = 1;
const PRICE_FACTOR_BASE: u64 = 10000;
const ONE_WEEK_SECOND: u64 = 7 * 24 * 3600;
const ORACLE_PRICE_MAX_AGE: u64 = 60;
const TWAP_INTERVAL: u64 = 7200;
const XAUM_DECIMAL: u8 = 9;
const USDC_DECIMAL: u8 = 6;
const MMT_PRICE_DECIMAL: u8 = 192;

// === Events ===

public struct TransferOwnership has copy, drop {
    old_owner: address,
    new_owner: address,
}

public struct SetOperator has copy, drop {
    old_operator: address,
    new_operator: address,
}

public struct SetCoinHolder has copy, drop {
    old_coin_holder: address,
    new_coin_holder: address,
}

public struct SetCoinWhitelist has copy, drop {
    coin: TypeName,
    decimal: u8,
    accepted: bool,
}

public struct SetPriceOracle has copy, drop {
    new_oracle_feed_id: vector<u8>,
}

public struct SetDexPool has copy, drop {
    new_dex_pool: ID,
}

public struct SetPriceFactor has copy, drop {
    weekday: u64,
    weekend: u64,
}

public struct SetWeekdayParam has copy, drop {
    weekday_start_time: u64,
    weekday_duration: u64,
}

public struct SetPriceDeviationRatio has copy, drop {
    old_price_deviation_ratio: u64,
    new_price_deviation_ratio: u64,
}

public struct SetPriceCheck has copy, drop {
    check: bool,
}

public struct SetXaum has copy, drop {
    xaum: TypeName,
}

public struct Swap has copy, drop {
    sender: address,
    coin_in: TypeName,
    amount_in: u64,
    amount_out: u64,
}

public struct UpdateUserWhitelist has copy, drop {
    cap_id: ID,
    accepted: bool,
}

public struct AddUserWhitelist has copy, drop {
    user: address,
    cap_id: ID,
}

// === Structs ===

public struct SwapCap has key, store {
    id: UID,
    owner: address,
    class: u64, // for future use
    version: u64, // for future use
}

public struct State has key {
    id: UID,
    version: u64,
    upgrade_cap_id: Option<ID>,
    owner: address,
    operator: address,
    coin_holder: address,
    xaum: Option<TypeName>,
    xaum_price_oracle_feed_id: Option<vector<u8>>,
    dex_pool: Option<ID>,
    price_factor_weekday: u64,
    price_factor_weekend: u64,
    weekday_start_time: u64,
    weekday_duration: u64,
    price_deviation_ratio: u64,
    price_check: bool,
    coin_whitelist: table::Table<TypeName, u8>, // coin typename => coin decimal
    user_whitelist: table::Table<ID, bool>,
    balances: bag::Bag,
}

// === Initialization ===
fun init(ctx: &mut TxContext) {
    let owner = ctx.sender();
    let state = State {
        id: object::new(ctx),
        version: VERSION,
        upgrade_cap_id: option::none(),
        owner,
        operator: owner,
        coin_holder: owner,
        xaum: option::none(),
        xaum_price_oracle_feed_id: option::none(),
        dex_pool: option::none(),
        price_factor_weekday: PRICE_FACTOR_BASE,
        price_factor_weekend: PRICE_FACTOR_BASE,
        weekday_start_time: 0,
        weekday_duration: 0,
        price_deviation_ratio: 0,
        price_check: false,
        coin_whitelist: table::new<TypeName, u8>(ctx),
        user_whitelist: table::new<ID, bool>(ctx),
        balances: bag::new(ctx),
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
    assert!(state.upgrade_cap_id.contains(&object::id(&upgrade_cap)), EUpgradeCapInvalid);
    transfer::public_transfer(upgrade_cap, new_owner);

    state.owner = new_owner;
    event::emit(TransferOwnership { old_owner, new_owner });
}

entry fun set_operator(state: &mut State, new_operator: address, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let old_operator = state.operator;
    state.operator = new_operator;
    event::emit(SetOperator { old_operator, new_operator });
}

entry fun set_coin_holder(state: &mut State, new_coin_holder: address, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let old_coin_holder = state.coin_holder;
    state.coin_holder = new_coin_holder;
    event::emit(SetCoinHolder { old_coin_holder, new_coin_holder });
}

entry fun set_xaum<T>(state: &mut State, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let xaum = type_name::get<T>();
    state.xaum = option::some(xaum);
    event::emit(SetXaum { xaum: xaum });
}

entry fun set_coin_whitelist<T>(state: &mut State, accepted: bool, decimal: u8, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let coin = type_name::get<T>();
    if (state.coin_whitelist.contains(coin)) {
        if (!accepted) {
            state.coin_whitelist.remove(coin);
        }
    } else {
        if (accepted) {
            state.coin_whitelist.add(coin, decimal);
            if (!state.balances.contains(coin)) {
                state.balances.add(coin, balance::zero<T>());
            };
        }
    };
    event::emit(SetCoinWhitelist { coin, decimal, accepted });
}

entry fun set_xaum_price_oracle_feed_id(
    state: &mut State,
    new_oracle_feed_id: vector<u8>,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    state.xaum_price_oracle_feed_id = option::some(new_oracle_feed_id);
    event::emit(SetPriceOracle { new_oracle_feed_id });
}

entry fun set_dex_pool(state: &mut State, new_dex_pool: ID, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    state.dex_pool = option::some(new_dex_pool);
    event::emit(SetDexPool { new_dex_pool });
}

entry fun set_price_factor(state: &mut State, weekday: u64, weekend: u64, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    state.price_factor_weekday = weekday;
    state.price_factor_weekend = weekend;
    event::emit(SetPriceFactor { weekday, weekend });
}

entry fun set_weekday_param(
    state: &mut State,
    weekday_start_time: u64,
    weekday_duration: u64,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    state.weekday_start_time = weekday_start_time;
    state.weekday_duration = weekday_duration;
    event::emit(SetWeekdayParam { weekday_start_time, weekday_duration });
}

entry fun set_price_deviation_ratio(
    state: &mut State,
    new_price_deviation_ratio: u64,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    let old_price_deviation_ratio = state.price_deviation_ratio;
    state.price_deviation_ratio = new_price_deviation_ratio;
    event::emit(SetPriceDeviationRatio { old_price_deviation_ratio, new_price_deviation_ratio });
}

entry fun set_price_check(state: &mut State, check: bool, ctx: &TxContext) {
    check_version(state);
    check_owner(state, ctx);
    state.price_check = check;
    event::emit(SetPriceCheck { check });
}

entry fun add_user_whitelist(state: &mut State, user: address, ctx: &mut TxContext) {
    check_version(state);
    check_owner(state, ctx);
    let swap_cap = SwapCap {
        id: object::new(ctx),
        owner: user,
        class: 0,
        version: VERSION,
    };
    let cap_id = object::id(&swap_cap);
    state.user_whitelist.add(cap_id, true);
    event::emit(AddUserWhitelist { user, cap_id });
    event::emit(UpdateUserWhitelist { cap_id, accepted: true });
    transfer::public_transfer(swap_cap, user);
}

entry fun update_user_whitelist(
    state: &mut State,
    user_cap_id: ID,
    accepted: bool,
    ctx: &TxContext,
) {
    check_version(state);
    check_owner(state, ctx);
    if (state.user_whitelist.contains(user_cap_id)) {
        if (!accepted) {
            state.user_whitelist.remove(user_cap_id);
        }
    } else {
        if (accepted) {
            state.user_whitelist.add(user_cap_id, true);
        }
    };
    event::emit(UpdateUserWhitelist { cap_id: user_cap_id, accepted });
}

entry fun migrate(state: &mut State, ctx: &TxContext) {
    check_owner(state, ctx);
    assert!(state.version < VERSION, EWrongVersion);
    state.version = VERSION;
}

// === Operator Functions ===

entry fun withdraw<T>(state: &mut State, amount: u64, ctx: &mut TxContext) {
    check_version(state);
    check_operator(state, ctx);
    let balance = get_balance_mut<T>(&mut state.balances);
    let coin = coin::take(balance, amount, ctx);
    transfer::public_transfer(coin, state.coin_holder);
}

entry fun withdraw_to_state<T>(state: &mut State, ctx: &mut TxContext) {
    check_version(state);
    check_operator(state, ctx);
    let balance = get_balance_mut<T>(&mut state.balances);
    let amount = balance.value();
    let coin = coin::take(balance, amount, ctx);
    transfer::public_transfer(coin, object::uid_to_address(&state.id));
}

entry fun accept_payment<T>(state: &mut State, sent: Receiving<Coin<T>>, ctx: &TxContext) {
    check_version(state);
    check_operator(state, ctx);
    let coin_in = transfer::public_receive(&mut state.id, sent);
    let tn = type_name::get<T>();
    if (!state.balances.contains(tn)) {
        state.balances.add(tn, balance::zero<T>());
    };
    let balance = state.balances.borrow_mut(tn);
    coin::put(balance, coin_in);
}

public fun swap<InCoinType, XAUM, PairTokenType>(
    state: &mut State,
    user_cap: &SwapCap,
    coin_in: &mut Coin<InCoinType>,
    amount_in: u64,
    oracle_dex_pool: &Pool<XAUM, PairTokenType>,
    price_info_object: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<XAUM> {
    check_version(state);
    let coin_out_tn = type_name::get<XAUM>();
    assert!(state.xaum.contains(&coin_out_tn), EInvalidCoinOutType);
    assert!(state.user_whitelist.contains(object::id(user_cap)), EUserNotInWhitelist);
    let (coin_in_tn, coin_in_decimal) = check_coin<InCoinType>(state);
    let balance = coin_in.value();
    assert!(balance >= amount_in && amount_in > 0, EInvalidAmountIn);

    let coin_received = coin::split<InCoinType>(coin_in, amount_in, ctx);
    merge_coin_into_balances(state, coin_received);

    let (price, oracle_price_decimal) = get_price_from_oracle(state, price_info_object, clock);
    if (state.price_check) {
        assert!(state.dex_pool.contains(&object::id(oracle_dex_pool)), EInvalidDexPool);
        let dex_price =
            get_twap_price_from_dex<XAUM, PairTokenType>(
                oracle_dex_pool,
                oracle_price_decimal as u8,
                clock,
            ) as u64;
        assert!(
            dex_price * (PRICE_FACTOR_BASE - state.price_deviation_ratio) / PRICE_FACTOR_BASE <= price,
            EOraclePriceTooLow,
        );
        assert!(
            dex_price * (PRICE_FACTOR_BASE + state.price_deviation_ratio) / PRICE_FACTOR_BASE >= price,
            EOraclePriceTooHigh,
        );
    };
    let amount_out =
        amount_in * u64::pow(10, (XAUM_DECIMAL + (oracle_price_decimal as u8) - coin_in_decimal)) / price;
    assert!(amount_out <= get_balance_amount<XAUM>(state), EInvalidAmountOut);
    let coin_out = coin::take(get_balance_mut<XAUM>(&mut state.balances), amount_out, ctx);
    event::emit(Swap { sender: ctx.sender(), coin_in: coin_in_tn, amount_in, amount_out });
    coin_out
}

// === View Functions ===

public fun get_twap_price_from_dex<X, Y>(
    pool: &Pool<X, Y>,
    pyth_oracle_price_decimal: u8,
    clock: &Clock,
): u256 {
    let mut seconds_ago = vector::empty<u64>();
    seconds_ago.push_back(TWAP_INTERVAL);
    seconds_ago.push_back(0); // current time
    let (mut tick_cumulative, _cumulative_liquidity) = pool::observe(pool, seconds_ago, clock);
    assert!(vector::length(&tick_cumulative) == 2, EInvalidTickCumulativeLength);
    let tick_avg = i64::div(
        i64::sub(vector::pop_back(&mut tick_cumulative), vector::pop_back(&mut tick_cumulative)),
        i64::from(TWAP_INTERVAL),
    );
    let tick_ave_i32 = if (mmt_v3::i64::is_neg(tick_avg)) {
        i32::neg_from(i64::abs_u64(tick_avg) as u32)
    } else {
        i32::from(i64::abs_u64(tick_avg) as u32)
    };
    let sqrt_price_x96 = tick_math::get_sqrt_price_at_tick(tick_ave_i32);
    // token0 is xaum. todo: check if token0 is xaum.
    10u256.pow(XAUM_DECIMAL - USDC_DECIMAL + pyth_oracle_price_decimal) * (sqrt_price_x96 as u256) * (sqrt_price_x96 as u256) / (1u256 << MMT_PRICE_DECIMAL)
}

public fun get_price_from_oracle(
    state: &State,
    price_info_object: &PriceInfoObject,
    clock: &Clock,
): (u64, u64) {
    let price_struct = pyth::get_price_no_older_than(
        price_info_object,
        clock,
        ORACLE_PRICE_MAX_AGE,
    );
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
    assert!(state.xaum_price_oracle_feed_id.contains(&price_id), EInvalidOraclePriceId);

    let decimal_i64 = price::get_expo(&price_struct);
    let decimal_u64 = i64_pyth::get_magnitude_if_negative(&decimal_i64);
    let price_i64 = price::get_price(&price_struct);
    let price_u64 = i64_pyth::get_magnitude_if_positive(&price_i64);

    let (price, decimal) = if (in_weekday(state, clock)) {
        (
            price_u64 * (state.price_factor_weekday + PRICE_FACTOR_BASE) / PRICE_FACTOR_BASE,
            decimal_u64,
        )
    } else {
        (
            price_u64 * (state.price_factor_weekend + PRICE_FACTOR_BASE) / PRICE_FACTOR_BASE,
            decimal_u64,
        )
    };
    (price, decimal)
}

public fun get_balance_amount<T>(state: &State): u64 {
    let tn = type_name::get<T>();
    let balance: &Balance<T> = bag::borrow(&state.balances, tn);
    balance.value()
}

// === Helper Functions ===

public fun package_address(_state: &State): address {
    address::from_ascii_bytes(type_name::get_with_original_ids<State>().get_address().as_bytes())
}

// === Private Functions ===

fun in_weekday(state: &State, clock: &Clock): bool {
    let timestamp = clock.timestamp_ms() / 1000;
    (timestamp - state.weekday_start_time) % ONE_WEEK_SECOND < state.weekday_duration
}

fun merge_coin_into_balances<T>(state: &mut State, coin: Coin<T>) {
    if (coin.value() == 0) {
        coin::destroy_zero(coin);
    } else {
        coin::put(get_balance_mut<T>(&mut state.balances), coin);
    };
}

fun get_balance_mut<T>(balances: &mut bag::Bag): &mut Balance<T> {
    let tn = type_name::get<T>();
    assert!(balances.contains(tn), EBalanceNotExists);
    let balance = bag::borrow_mut(balances, tn);
    balance
}

fun check_coin<T>(state: &State): (TypeName, u8) {
    let coin_tn = type_name::get<T>();
    assert!(state.coin_whitelist.contains(coin_tn), ECoinNotInWhitelist);
    let decimal = *state.coin_whitelist.borrow(coin_tn);
    (coin_tn, decimal)
}

fun check_version(state: &State) {
    assert!(state.version == VERSION, EWrongVersion);
}

fun check_owner(state: &State, ctx: &TxContext) {
    assert!(ctx.sender() == state.owner, ENotOwner);
}

fun check_operator(state: &State, ctx: &TxContext) {
    assert!(ctx.sender() == state.operator, ENotOperator);
}

// === Test Functions ===

#[test_only]
public(package) fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun operator(state: &State): address {
    state.operator
}

#[test_only]
public fun coin_holder(state: &State): address {
    state.coin_holder
}

#[test_only]
public fun xaum(state: &State): Option<TypeName> {
    state.xaum
}

#[test_only]
public fun is_coin_whitelisted<T>(state: &State): bool {
    state.coin_whitelist.contains(type_name::get<T>())
}

#[test_only]
public fun xaum_price_oracle_feed_id(state: &State): Option<vector<u8>> {
    state.xaum_price_oracle_feed_id
}

#[test_only]
public fun dex_pool(state: &State): Option<ID> {
    state.dex_pool
}
