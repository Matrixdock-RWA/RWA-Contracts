#[test_only]
module minter::minter_tests;

use minter::minter;
use std::type_name;
use sui::address;
use sui::clock;
use sui::coin;
use sui::event;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

const OWNER: address = @0xAD;
const ALICE: address = @0xA;
const POOLA: address = @0xB;
const POOLB: address = @0xC;
const VERSION: u64 = 1;

public struct USDT has drop {}

#[test]
fun test_minter() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        assert_eq(state.version(), VERSION);

        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_pool_account_b(&mut state, POOLB, ts.ctx());

        assert_eq(state.pool_account_a(), POOLA);
        assert_eq(state.pool_account_b(), POOLB);
        ts::return_shared(state);
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_accepted_by_a(
            &mut state,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            true,
            ts.ctx(),
        );
        minter::set_accepted_by_b(
            &mut state,
            address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
            true,
            ts.ctx(),
        );
        assert!(
            minter::accepted_by_a(
                &state,
                address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            ),
        );
        assert!(
            minter::accepted_by_b(
                &state,
                address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
            ),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut usdt = coin::mint_for_testing<USDT>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_mint<USDT>(
            &state,
            &mut usdt,
            address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
            100,
            10,
            5,
            999,
            &_clock,
            ts.ctx(),
        );
        assert_eq(coin::value(&usdt), 900);
        assert_eq(event::num_events(), 1);
        assert_eq(
            event::events_by_type<minter::MintRequest>().pop_back(),
            minter::new_mint_request_event(
                address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
                address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
                ALICE,
                POOLA,
                100,
                10,
                5,
            ),
        );
        transfer::public_transfer(usdt, ALICE);
        ts::return_shared(state);
        clock::destroy_for_testing(_clock);
    };
    {
        ts.next_tx(POOLA);
        let usdt = ts.take_from_sender<coin::Coin<USDT>>();
        assert_eq(coin::value(&usdt), 100);
        ts.return_to_sender(usdt);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut sui = coin::mint_for_testing<SUI>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_redeem<SUI>(
            &state,
            &mut sui,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            100,
            10,
            5,
            999,
            &_clock,
            ts.ctx(),
        );
        assert_eq(coin::value(&sui), 900);
        assert_eq(event::num_events(), 1);
        assert_eq(
            event::events_by_type<minter::RedeemRequest>().pop_back(),
            minter::new_redeem_request_event(
                address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
                address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
                ALICE,
                POOLB,
                100,
                10,
                5,
            ),
        );
        transfer::public_transfer(sui, ALICE);
        ts::return_shared(state);
        clock::destroy_for_testing(_clock);
    };
    {
        ts.next_tx(POOLB);
        let sui = ts.take_from_sender<coin::Coin<SUI>>();
        assert_eq(coin::value(&sui), 100);
        ts.return_to_sender(sui);
    };
    ts.end();
}

#[test, expected_failure(abort_code = minter::EInvalidTokenForMint)]
fun invalid_token_for_mint_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_a(
            &mut state,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            true,
            ts.ctx(),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut sui = coin::mint_for_testing<SUI>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_mint<SUI>(
            &state,
            &mut sui,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            100,
            10,
            5,
            999,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInvalidTimestamp)]
fun invalid_timestamp_for_mint_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_a(
            &mut state,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            true,
            ts.ctx(),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut usdt = coin::mint_for_testing<USDT>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_mint<USDT>(
            &state,
            &mut usdt,
            address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
            100,
            10,
            5,
            900,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInvalidTokenForMint)]
fun invalid_token_for_mint_when_remove_accepted_token() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_a(
            &mut state,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            true,
            ts.ctx(),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_accepted_by_a(
            &mut state,
            address::from_ascii_bytes(type_name::get<USDT>().get_address().as_bytes()),
            false,
            ts.ctx(),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut usdt = coin::mint_for_testing<USDT>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_mint<USDT>(
            &state,
            &mut usdt,
            address::from_ascii_bytes(type_name::get<SUI>().get_address().as_bytes()),
            100,
            10,
            5,
            1000,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}
