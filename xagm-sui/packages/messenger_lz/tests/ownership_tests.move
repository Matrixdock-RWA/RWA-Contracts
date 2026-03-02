#[test_only]
module messenger_lz::ownership_tests;

use messenger_lz::messenger_oapp::{Self, State, TransferOwnershipReq};
use std::unit_test::assert_eq;
use sui::event;
use sui::package::{test_publish, UpgradeCap};
use sui::test_scenario;

// test addresses
// const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

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

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_owner_req_err_not_owner() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
        state.request_transfer_ownership(BOB, upgrade_cap, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::ENotNewOwner)]
fun set_owner_exec_err_not_new_owner() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
        state.request_transfer_ownership(ALICE, upgrade_cap, scenario.ctx());
        test_scenario::return_shared(state);
    };

    // execute
    scenario.next_tx(BOB);
    {
        let mut state = scenario.take_shared<State>();
        let req = scenario.take_shared<TransferOwnershipReq>();
        messenger_oapp::execute_transfer_ownership(&mut state, req, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::EUpgradeCapInvalid)]
fun set_owner_req_err_upgrade_cap_invalid() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());

        let upgrade_cap2 = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        state.request_transfer_ownership(ALICE, upgrade_cap2, scenario.ctx());
    };
    abort
}

#[test]
fun set_owner_ok() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
        state.request_transfer_ownership(ALICE, upgrade_cap, scenario.ctx());
        assert_eq!(state.owner(), ADMIN);
        test_scenario::return_shared(state);
    };

    // execute
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        let req = scenario.take_shared<TransferOwnershipReq>();
        messenger_oapp::execute_transfer_ownership(&mut state, req, scenario.ctx());
        assert_eq!(state.owner(), ALICE);
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };

    // check upgrade cap
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<State>();
        let upgrade_cap = scenario.take_from_sender<UpgradeCap>();
        assert_eq!(upgrade_cap.package(), state.package_address().to_id());
        scenario.return_to_sender(upgrade_cap);
        test_scenario::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_owner_revoke_err_not_owner() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
        state.request_transfer_ownership(ALICE, upgrade_cap, scenario.ctx());
        assert_eq!(state.owner(), ADMIN);
        test_scenario::return_shared(state);
    };

    // revoke
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<State>();
        let req = scenario.take_shared<TransferOwnershipReq>();
        state.revoke_transfer_ownership(req, scenario.ctx());
    };
    abort
}

#[test]
fun set_owner_revoke_ok() {
    let mut scenario = init_messenger_oapp();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        state.init_upgrade_cap_id(&upgrade_cap, scenario.ctx());
        state.request_transfer_ownership(ALICE, upgrade_cap, scenario.ctx());
        assert_eq!(state.owner(), ADMIN);
        test_scenario::return_shared(state);
    };

    // revoke
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<State>();
        let req = scenario.take_shared<TransferOwnershipReq>();
        state.revoke_transfer_ownership(req, scenario.ctx());
        test_scenario::return_shared(state);
    };

    // check upgrade cap
    scenario.next_tx(ADMIN);
    {
        let _upgrade_cap = scenario.take_from_sender<UpgradeCap>();
        // assert_eq!(object::id(&upgrade_cap), object::id_from_address(@123));
        scenario.return_to_sender(_upgrade_cap);
    };

    scenario.end();
}
