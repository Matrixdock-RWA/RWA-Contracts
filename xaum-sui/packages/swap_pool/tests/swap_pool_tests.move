#[test_only]
module swap_pool::swap_pool_tests;

use std::type_name;
use sui::test_scenario;
use sui::test_utils::assert_eq;
use swap_pool::swap_pool::{Self, State};

// test addresses
const SYS: address = @0x0;
const OWNER: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

// test Coins
public struct XAUM has drop {}
public struct USDC has drop {}

fun init_swap_pool(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(OWNER);
    swap_pool::init_for_testing(scenario.ctx());
    scenario
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_operator_err_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_operator(&mut state, ALICE, scenario.ctx());
    };
    abort
}

#[test]
fun set_operator_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_operator(&mut state, ALICE, scenario.ctx());
        assert_eq(state.operator(), ALICE);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_coin_holder_err_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_coin_holder(&mut state, ALICE, scenario.ctx());
    };
    abort
}

#[test]
fun set_coin_holder_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_coin_holder(&mut state, ALICE, scenario.ctx());
        assert_eq(state.coin_holder(), ALICE);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_xaum_err_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_xaum<XAUM>(&mut state, scenario.ctx());
    };
    abort
}

#[test]
fun set_xaum_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_xaum<XAUM>(&mut state, scenario.ctx());
        assert_eq(state.xaum().contains(&type_name::get<XAUM>()), true);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_coin_whitelist_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_coin_whitelist<XAUM>(&mut state, true, scenario.ctx());
    };
    abort
}

#[test]
fun set_coin_whitelist_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        assert_eq(state.is_coin_whitelisted<USDC>(), false);
        swap_pool::set_coin_whitelist<USDC>(&mut state, true, scenario.ctx());
        assert_eq(state.is_coin_whitelisted<USDC>(), true);
        test_scenario::return_shared(state);
    };

    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_coin_whitelist<USDC>(&mut state, false, scenario.ctx());
        assert_eq(state.is_coin_whitelisted<USDC>(), false);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_xaum_price_oracle_feed_id_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_xaum_price_oracle_feed_id(&mut state, vector::empty(), scenario.ctx());
    };
    abort
}

#[test]
fun set_xaum_price_oracle_feed_id_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        swap_pool::set_xaum_price_oracle_feed_id(&mut state, b"feed_id", scenario.ctx());
        assert_eq(state.xaum_price_oracle_feed_id().contains(&b"feed_id"), true);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = swap_pool::ENotOwner)]
fun set_dex_pool_not_owner() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        let dex_pool_id = object::id_from_address(@0x1234);
        swap_pool::set_dex_pool(&mut state, dex_pool_id, scenario.ctx());
    };
    abort
}

#[test]
fun set_dex_pool_ok() {
    let mut scenario = init_swap_pool();
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<State>();
        let dex_pool_id = object::id_from_address(@0x1234);
        swap_pool::set_dex_pool(&mut state, dex_pool_id, scenario.ctx());
        assert_eq(state.dex_pool().contains(&dex_pool_id), true);
        test_scenario::return_shared(state);
    };
    scenario.end();
}
