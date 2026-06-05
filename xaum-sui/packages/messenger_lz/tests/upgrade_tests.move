#[test_only]
module messenger_lz::upgrade_tests;

use messenger_lz::messenger_oapp::{Self, State};
use std::unit_test::assert_eq;
use sui::package::test_publish;
use sui::test_scenario;

const VERSION: u64 = 2;

// test addresses
// const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
// const BOB: address = @0xB0B;

fun init_messenger_oapp(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        // xaum::init_for_testing(scenario.ctx());
        messenger_oapp::init_for_testing(scenario.ctx());
        // endpoint_v2::init_for_test(scenario.ctx());
    };
    scenario
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun init_upgrade_cap_id_err_not_owner() {
    let mut scenario = init_messenger_oapp();

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::EUpgradeCapInvalid)]
fun init_upgrade_cap_id_err_not_matching() {
    let mut scenario = init_messenger_oapp();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = std::option::EOPTION_IS_SET)]
fun init_upgrade_cap_id_err_not_none() {
    let mut scenario = init_messenger_oapp();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx()); // ok
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx()); // error!
    };
    abort
}

#[test]
fun init_upgrade_cap_id_ok() {
    let mut scenario = init_messenger_oapp();

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx()); // ok
        assert_eq!(state.upgrade_cap_id(), option::some(object::id(&upgrade_cap)));
        transfer::public_share_object(upgrade_cap);
        test_scenario::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun migrate_err_not_owner() {
    let mut scenario = init_messenger_oapp();

    // migrate
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        state.migrate(scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::EWrongVersion)]
fun migrate_err_wrong_version() {
    let mut scenario = init_messenger_oapp();

    // migrate
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        state.set_version(2);
        state.migrate(scenario.ctx());
    };
    abort
}

#[test]
fun migrate_ok() {
    let mut scenario = init_messenger_oapp();

    // migrate
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        state.set_version(0);
        state.migrate(scenario.ctx());
        assert_eq!(state.version(), VERSION);
        test_scenario::return_shared(state);
    };

    scenario.end();
}
