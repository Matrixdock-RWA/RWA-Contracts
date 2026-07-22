#[test_only]
module minter::minter_tests;

use minter::minter;
use std::type_name;
use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::event;
use sui::package::{test_publish, UpgradeCap};
use sui::sui::SUI;
use sui::test_scenario as ts;

const OWNER: address = @0xAD;
const ALICE: address = @0xA;
const POOLA: address = @0xB;
const POOLB: address = @0xC;
const BOB: address = @0xD;
const VERSION: u64 = 1;
const EXTRADATA: vector<u8> = b"DATA";
const MIN_GOV_DELAY: u64 = 3600 * 24; // 1 day, mirrors module constant
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7 days, mirrors module constant

public struct USDT has drop {}

// === Ownership Transfer Tests ===

// happy path: owner requests, proposed owner personally accepts after gov_delay, and the
// escrowed UpgradeCap lands with the new owner.
#[test]
fun test_transfer_ownership() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    let upgrade_cap_id;
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        upgrade_cap_id = object::id(&upgrade_cap);
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);

        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);

        // step 1: request (escrows the cap into State)
        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        assert_eq!(state.next_owner(), option::some(BOB));
        assert_eq!(state.next_owner_et(), MIN_GOV_DELAY);
        assert_eq!(state.owner(), OWNER); // not changed yet

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        // step 2: proposed owner accepts after delay
        ts.next_tx(BOB);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing((MIN_GOV_DELAY + 1) * 1000);
        minter::accept_transfer_ownership(&mut state, &clock, ts.ctx());

        assert_eq!(state.owner(), BOB);
        assert_eq!(state.next_owner(), option::none());
        assert_eq!(state.next_owner_et(), 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(BOB);
        let upgrade_cap = ts.take_from_sender<UpgradeCap>();
        assert_eq!(object::id(&upgrade_cap), upgrade_cap_id);
        ts.return_to_sender(upgrade_cap);
    };
    ts.end();
}

// bootstrap: gov_delay is 0 on a fresh deploy, so an ownership transfer is immediately
// executable (deployer can hand over without waiting).
#[test]
fun test_transfer_ownership_bootstrap_no_wait() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        assert_eq!(state.gov_delay(), 0);
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());

        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        assert_eq!(state.next_owner_et(), 0); // matured immediately

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(BOB);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::accept_transfer_ownership(&mut state, &clock, ts.ctx());
        assert_eq!(state.owner(), BOB);
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    ts.end();
}

#[test]
fun test_revoke_transfer_ownership() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);

        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        assert_eq!(state.next_owner(), option::some(BOB));

        minter::revoke_transfer_ownership(&mut state, ts.ctx());
        assert_eq!(state.next_owner(), option::none());
        assert_eq!(state.next_owner_et(), 0);
        assert_eq!(state.owner(), OWNER); // unchanged

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        // cap returned to owner on revoke
        ts.next_tx(OWNER);
        let upgrade_cap = ts.take_from_sender<UpgradeCap>();
        ts.return_to_sender(upgrade_cap);
    };
    ts.end();
}

// after a revoke the owner may re-request (replay), proving revoke frees the pending slot.
#[test]
fun test_revoke_then_rerequest() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);

        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        minter::revoke_transfer_ownership(&mut state, ts.ctx());
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = ts.take_from_sender<UpgradeCap>();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, ALICE, upgrade_cap, &clock, ts.ctx());
        assert_eq!(state.next_owner(), option::some(ALICE));
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    ts.end();
}

// a second request while one is pending must revert (PRD §5.2: PendingOwnerExist).
#[test, expected_failure(abort_code = minter::EPendingOwnerExist)]
fun request_transfer_ownership_err_pending_exist() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let cap1 = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &cap1, ts.ctx());
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1000 * 1000);

        minter::request_transfer_ownership(&mut state, BOB, cap1, &clock, ts.ctx());
        let cap2 = test_publish(state.package_address().to_id(), ts.ctx());
        minter::request_transfer_ownership(&mut state, ALICE, cap2, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun request_transfer_ownership_err_not_owner() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(ALICE);
        let mut state: minter::State = ts.take_shared();
        let cap = test_publish(object::id_from_address(@0x1234), ts.ctx());
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, BOB, cap, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EUpgradeCapInvalid)]
fun request_transfer_ownership_err_invalid_cap() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let valid_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &valid_cap, ts.ctx());
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        let wrong_cap = test_publish(object::id_from_address(@0x1234), ts.ctx());
        minter::request_transfer_ownership(&mut state, BOB, wrong_cap, &clock, ts.ctx());
        transfer::public_share_object(valid_cap);
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENoOwnerTransferRequest)]
fun accept_transfer_ownership_err_no_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(BOB);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing((MIN_GOV_DELAY + 1) * 1000);
        minter::accept_transfer_ownership(&mut state, &clock, ts.ctx());
    };
    abort
}

// unrelated caller cannot accept: acceptance is bound to the pending proposed owner.
#[test, expected_failure(abort_code = minter::ENotNewOwner)]
fun accept_transfer_ownership_err_not_new_owner() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE); // not BOB
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing((MIN_GOV_DELAY + 1) * 1000);
        minter::accept_transfer_ownership(&mut state, &clock, ts.ctx());
    };
    abort
}

// the proposed owner cannot accept before the delay elapses.
#[test, expected_failure(abort_code = minter::EOwnerTransferNotReady)]
fun accept_transfer_ownership_err_not_ready() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(BOB);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing((MIN_GOV_DELAY - 1) * 1000);
        minter::accept_transfer_ownership(&mut state, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun revoke_transfer_ownership_err_not_owner() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let upgrade_cap = test_publish(state.package_address().to_id(), ts.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, ts.ctx());
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::request_transfer_ownership(&mut state, BOB, upgrade_cap, &clock, ts.ctx());
        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    {
        ts.next_tx(ALICE);
        let mut state: minter::State = ts.take_shared();
        minter::revoke_transfer_ownership(&mut state, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENoOwnerTransferRequest)]
fun revoke_transfer_ownership_err_no_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::revoke_transfer_ownership(&mut state, ts.ctx());
    };
    abort
}

// === Gov Delay Tests ===

// request → wait → execute, exercised against an armed gov_delay.
#[test]
fun test_set_gov_delay() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);

        // request: matures after the current gov_delay (MIN_GOV_DELAY); value not yet applied
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx());
        assert_eq!(state.gov_delay(), MIN_GOV_DELAY);
        assert_eq!(state.next_gov_delay(), option::some(MAX_GOV_DELAY));
        assert_eq!(state.next_gov_delay_et(), MIN_GOV_DELAY);

        // execute after maturity
        clock.set_for_testing((MIN_GOV_DELAY + 1) * 1000);
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx());
        assert_eq!(state.gov_delay(), MAX_GOV_DELAY);
        assert_eq!(state.next_gov_delay(), option::none());
        assert_eq!(state.next_gov_delay_et(), 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    ts.end();
}

// from bootstrap (gov_delay == 0) the first arming is immediately executable.
#[test]
fun test_set_gov_delay_from_bootstrap() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1000 * 1000);

        minter::set_gov_delay(&mut state, MIN_GOV_DELAY, &clock, ts.ctx()); // request, et = now
        assert_eq!(state.next_gov_delay_et(), 1000);
        minter::set_gov_delay(&mut state, MIN_GOV_DELAY, &clock, ts.ctx()); // execute immediately
        assert_eq!(state.gov_delay(), MIN_GOV_DELAY);

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    ts.end();
}

#[test]
fun test_revoke_set_gov_delay() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);

        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx());
        assert_eq!(state.next_gov_delay(), option::some(MAX_GOV_DELAY));

        minter::revoke_set_gov_delay(&mut state, ts.ctx());
        assert_eq!(state.next_gov_delay(), option::none());
        assert_eq!(state.gov_delay(), MIN_GOV_DELAY); // unchanged

        // idempotent replay: revoking again is a no-op
        minter::revoke_set_gov_delay(&mut state, ts.ctx());
        assert_eq!(state.next_gov_delay(), option::none());

        clock::destroy_for_testing(clock);
        ts::return_shared(state);
    };
    ts.end();
}

#[test, expected_failure(abort_code = minter::EGovDelayTooShort)]
fun set_gov_delay_err_too_short() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::set_gov_delay(&mut state, MIN_GOV_DELAY - 1, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EGovDelayTooLong)]
fun set_gov_delay_err_too_long() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY + 1, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun set_gov_delay_err_not_owner() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(ALICE);
        let mut state: minter::State = ts.take_shared();
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::set_gov_delay(&mut state, MIN_GOV_DELAY, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EGovDelayNotReady)]
fun set_gov_delay_err_not_ready() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx()); // request
        // try to execute before the delay elapses
        clock.set_for_testing((MIN_GOV_DELAY - 1) * 1000);
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EGovDelayArgsMismatch)]
fun set_gov_delay_err_args_mismatch() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_gov_delay_for_testing(&mut state, MIN_GOV_DELAY);
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(0);
        minter::set_gov_delay(&mut state, MAX_GOV_DELAY, &clock, ts.ctx()); // request MAX
        // executing with a different value must revert (revoke first)
        minter::set_gov_delay(&mut state, MIN_GOV_DELAY, &clock, ts.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun revoke_set_gov_delay_err_not_owner() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(ALICE);
        let mut state: minter::State = ts.take_shared();
        minter::revoke_set_gov_delay(&mut state, ts.ctx());
    };
    abort
}

// === Bootstrap Tests ===

// fresh deploy is disarmed (gov_delay == 0) and at the current VERSION.
#[test]
fun test_bootstrap_state() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let state: minter::State = ts.take_shared();
        assert_eq!(state.version(), VERSION);
        assert_eq!(state.gov_delay(), 0);
        assert_eq!(state.next_gov_delay(), option::none());
        ts::return_shared(state);
    };
    ts.end();
}

// === Minter Tests ===

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
        assert_eq!(state.version(), VERSION);

        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_pool_account_b(&mut state, POOLB, ts.ctx());

        assert_eq!(state.pool_account_a(), POOLA);
        assert_eq!(state.pool_account_b(), POOLB);
        ts::return_shared(state);
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_accepted_by_a<USDT>(
            &mut state,
            true,
            ts.ctx(),
        );
        minter::set_accepted_by_b<SUI>(
            &mut state,
            true,
            ts.ctx(),
        );
        assert!(
            minter::accepted_by_a(
                &state,
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            minter::accepted_by_b(
                &state,
                type_name::with_defining_ids<SUI>(),
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
        minter::request_to_mint<USDT, SUI>(
            &state,
            &mut usdt,
            100,
            10,
            5,
            999,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
        assert_eq!(coin::value(&usdt), 900);
        assert_eq!(event::num_events(), 1);
        assert_eq!(
            event::events_by_type<minter::MintRequest>().pop_back(),
            minter::new_mint_request_event(
                type_name::with_defining_ids<USDT>(),
                type_name::with_defining_ids<SUI>(),
                ALICE,
                POOLA,
                100,
                10,
                5,
                EXTRADATA,
            ),
        );
        transfer::public_transfer(usdt, ALICE);
        ts::return_shared(state);
        clock::destroy_for_testing(_clock);
    };
    {
        ts.next_tx(POOLA);
        let usdt = ts.take_from_sender<coin::Coin<USDT>>();
        assert_eq!(coin::value(&usdt), 100);
        ts.return_to_sender(usdt);
    };
    {
        ts.next_tx(ALICE);
        let state: minter::State = ts.take_shared();
        let mut sui = coin::mint_for_testing<SUI>(1000, ts.ctx());
        let mut _clock = clock::create_for_testing(ts.ctx());
        _clock.set_for_testing(1000 * 1000);
        minter::request_to_redeem<SUI, USDT>(
            &state,
            &mut sui,
            100,
            10,
            5,
            999,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
        assert_eq!(coin::value(&sui), 900);
        assert_eq!(event::num_events(), 1);
        assert_eq!(
            event::events_by_type<minter::RedeemRequest>().pop_back(),
            minter::new_redeem_request_event(
                type_name::with_defining_ids<SUI>(),
                type_name::with_defining_ids<USDT>(),
                ALICE,
                POOLB,
                100,
                10,
                5,
                EXTRADATA,
            ),
        );
        transfer::public_transfer(sui, ALICE);
        ts::return_shared(state);
        clock::destroy_for_testing(_clock);
    };
    {
        ts.next_tx(POOLB);
        let sui = ts.take_from_sender<coin::Coin<SUI>>();
        assert_eq!(coin::value(&sui), 100);
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
        minter::set_accepted_by_a<USDT>(
            &mut state,
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
        minter::request_to_mint<SUI, USDT>(
            &state,
            &mut sui,
            100,
            10,
            5,
            999,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInsufficientBalance)]
fun insufficient_token_balance_for_mint_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_a(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_a<USDT>(
            &mut state,
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
        minter::request_to_mint<USDT, SUI>(
            &state,
            &mut usdt,
            1001,
            10,
            5,
            999,
            EXTRADATA,
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
        minter::set_accepted_by_a<USDT>(
            &mut state,
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
        minter::request_to_mint<USDT, SUI>(
            &state,
            &mut usdt,
            100,
            10,
            5,
            900,
            EXTRADATA,
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
        minter::set_accepted_by_a<USDT>(
            &mut state,
            true,
            ts.ctx(),
        );
        ts::return_shared(state);
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_accepted_by_a<USDT>(
            &mut state,
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
        minter::request_to_mint<USDT, SUI>(
            &state,
            &mut usdt,
            100,
            10,
            5,
            1000,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInvalidTokenForRedeem)]
fun invalid_token_for_redeem_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_b(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_b<SUI>(
            &mut state,
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
        minter::request_to_redeem<USDT, USDT>(
            &state,
            &mut usdt,
            100,
            10,
            5,
            999,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInvalidTimestamp)]
fun invalid_timestamp_for_redeem_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_b(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_b<SUI>(
            &mut state,
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
        minter::request_to_redeem<SUI, USDT>(
            &state,
            &mut sui,
            100,
            10,
            5,
            900,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EInsufficientBalance)]
fun insufficient_token_balance_for_redeem_request() {
    let mut ts = ts::begin(@0x0);
    {
        ts.next_tx(OWNER);
        minter::create_minter(ts.ctx());
    };
    {
        ts.next_tx(OWNER);
        let mut state: minter::State = ts.take_shared();
        minter::set_pool_account_b(&mut state, POOLA, ts.ctx());
        minter::set_accepted_by_b<SUI>(
            &mut state,
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
        minter::request_to_redeem<SUI, USDT>(
            &state,
            &mut sui,
            1001,
            10,
            5,
            999,
            EXTRADATA,
            &_clock,
            ts.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun init_upgrade_cap_id_err_not_owner() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<minter::State>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EUpgradeCapInvalid)]
fun init_upgrade_cap_id_err_not_matching() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };

    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = minter::EUpgradeCapIdNotNone)]
fun init_upgrade_cap_id_err_not_none() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };

    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx()); // ok
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx()); // error!
    };
    abort
}

#[test]
fun init_upgrade_cap_id_ok() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };

    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        minter::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx()); // ok
        assert_eq!(state.upgrade_cap_id(), option::some(object::id(&upgrade_cap)));
        transfer::public_share_object(upgrade_cap);
        ts::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = minter::ENotOwner)]
fun set_accepted_token_by_a_err_not_owner() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_a<USDT>(
            &mut state,
            true,
            scenario.ctx(),
        );
    };
    abort
}

#[test]
fun set_accepted_token_by_a_ok() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_a<USDT>(
            &mut state,
            true,
            scenario.ctx(),
        );
        minter::set_accepted_by_a<SUI>(
            &mut state,
            false,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            state.accepted_by_a(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            !state.accepted_by_a(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_a<USDT>(
            &mut state,
            false,
            scenario.ctx(),
        );
        minter::set_accepted_by_a<SUI>(
            &mut state,
            true,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            !state.accepted_by_a(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            state.accepted_by_a(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    // reenter
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_a<USDT>(
            &mut state,
            false,
            scenario.ctx(),
        );
        minter::set_accepted_by_a<SUI>(
            &mut state,
            true,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            !state.accepted_by_a(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            state.accepted_by_a(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    scenario.end();
}

#[test]
fun set_accepted_token_by_b_ok() {
    let mut scenario = ts::begin(@0x0);
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_b<USDT>(
            &mut state,
            true,
            scenario.ctx(),
        );
        minter::set_accepted_by_b<SUI>(
            &mut state,
            false,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            state.accepted_by_b(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            !state.accepted_by_b(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_b<USDT>(
            &mut state,
            false,
            scenario.ctx(),
        );
        minter::set_accepted_by_b<SUI>(
            &mut state,
            true,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            !state.accepted_by_b(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            state.accepted_by_b(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    // reenter
    scenario.next_tx(OWNER);
    {
        let mut state = scenario.take_shared<minter::State>();
        minter::set_accepted_by_b<USDT>(
            &mut state,
            false,
            scenario.ctx(),
        );
        minter::set_accepted_by_b<SUI>(
            &mut state,
            true,
            scenario.ctx(),
        );
        ts::return_shared(state);
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        assert!(
            !state.accepted_by_b(
                type_name::with_defining_ids<USDT>(),
            ),
        );
        assert!(
            state.accepted_by_b(
                type_name::with_defining_ids<SUI>(),
            ),
        );
        ts::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = minter::EZeroValue)]
fun request_to_mint_err_zero_value() {
    let mut scenario = ts::begin(@0x0);
    let mut _clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        let mut usdt = coin::mint_for_testing<USDT>(1000, scenario.ctx());
        state.request_to_mint<USDT, SUI>(
            &mut usdt,
            0,
            10,
            5,
            999,
            b"data",
            &_clock,
            scenario.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = minter::EZeroValue)]
fun request_to_redeem_err_zero_value() {
    let mut scenario = ts::begin(@0x0);
    let mut _clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    {
        minter::create_minter(scenario.ctx());
    };
    scenario.next_tx(OWNER);
    {
        let state = scenario.take_shared<minter::State>();
        let mut usdt = coin::mint_for_testing<USDT>(1000, scenario.ctx());
        state.request_to_redeem<USDT, SUI>(
            &mut usdt,
            0,
            10,
            5,
            999,
            b"data",
            &_clock,
            scenario.ctx(),
        );
    };
    abort
}
