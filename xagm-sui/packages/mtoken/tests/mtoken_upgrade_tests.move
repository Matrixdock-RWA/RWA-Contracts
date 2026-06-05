#[test_only]
module mtoken::mtoken_upgrade_tests;

use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken;
use std::unit_test::assert_eq;
use sui::package::test_publish;
use sui::test_scenario;

// constants are not exported, so we need to redefine them here
const VERSION: u64 = 4;
const INIT_DELAY: u64 = 0;
const INIT_GOV_DELAY: u64 = 5;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;

fun init_xagm(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(SYS);
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    scenario
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun init_upgrade_cap_id_err_not_owner() {
    let mut scenario = init_xagm();

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EUpgradeCapInvalid)]
fun init_upgrade_cap_id_err_not_matching() {
    let mut scenario = init_xagm();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EUpgradeCapIdNotNone)]
fun init_upgrade_cap_id_err_not_none() {
    let mut scenario = init_xagm();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap1 = test_publish(state.package_address().to_id(), scenario.ctx());
        let upgrade_cap2 = test_publish(state.package_address().to_id(), scenario.ctx());
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap1, scenario.ctx()); // ok
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap2, scenario.ctx()); // error!
    };
    abort
}

#[test]
fun init_upgrade_cap_id_ok() {
    let mut scenario = init_xagm();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        let cap_id = object::id(&upgrade_cap);
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
        assert_eq!(state.upgrade_cap_id(), option::some(cap_id));
        transfer::public_transfer(upgrade_cap, ADMIN);
        test_scenario::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun migrate_err_not_owner() {
    let mut scenario = init_xagm();

    // migrate
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::migrate(&mut state, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EWrongVersion)]
fun migrate_err_wrong_version() {
    let mut scenario = init_xagm();

    // migrate
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.set_version(VERSION + 1);
        mtoken::migrate(&mut state, scenario.ctx());
    };
    abort
}

#[test]
fun migrate_ok() {
    let mut scenario = init_xagm();

    // migrate
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.set_version(0);
        mtoken::migrate(&mut state, scenario.ctx());
        assert_eq!(state.version(), VERSION);
        test_scenario::return_shared(state);
    };

    scenario.end();
}
