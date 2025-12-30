#[test_only]
module messenger_lz::messenger_oapp_tests;

use call::call::Call;
use call::call_cap;
use endpoint_v2::endpoint_send::SendParam;
use endpoint_v2::endpoint_v2::{Self, EndpointV2};
use endpoint_v2::messaging_channel::MessagingChannel;
use endpoint_v2::messaging_receipt::MessagingReceipt;
use messenger_lz::messenger_oapp::{Self, State, SendContext};
use mtoken::mtoken::{Self, State as MtState, MessengerCap};
use oapp::oapp::OApp;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;
use utils::bytes32;
use xaum::xaum::{Self, XAUM};

// test addresses
// const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
// const BOB: address = @0xB0B;

fun init_messenger_oapp(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        xaum::init_for_testing(scenario.ctx());
        messenger_oapp::init_for_testing(scenario.ctx());
        endpoint_v2::init_for_test(scenario.ctx());
    };
    scenario
}

fun register_oapp(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let mut endpoint = scenario.take_shared<EndpointV2>();
        let lz_receive_info = vector::empty();
        state.register_oapp(
            &my_oapp,
            &mut endpoint,
            lz_receive_info,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
    };
}

fun set_oapp_info(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    lz_receive_info: vector<u8>,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let mut endpoint = scenario.take_shared<EndpointV2>();
        state.set_oapp_info(
            &my_oapp,
            &mut endpoint,
            lz_receive_info,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
    }
}

fun set_peer(scenario: &mut test_scenario::Scenario, caller: address, eid: u32, peer: vector<u8>) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let mut my_oapp = scenario.take_shared<OApp>();
        let endpoint = scenario.take_shared<EndpointV2>();
        let mut channel = scenario.take_shared<MessagingChannel>();

        state.set_peer(
            &mut my_oapp,
            &endpoint,
            &mut channel,
            eid,
            peer,
            scenario.ctx(),
        );

        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
        test_scenario::return_shared(channel);
    }
}

fun set_paused(scenario: &mut test_scenario::Scenario, caller: address, paused: bool) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<State>();
        state.set_paused(paused, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun create_new_messenger_cap(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    holder: address,
) {
    scenario.next_tx(caller);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        mt_state.cc_new_messenger_cap(holder, scenario.ctx());
        test_scenario::return_shared(mt_state);
    };
}

fun init_messenger_cap(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<State>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        state.init_messenger_cap(msg_cap, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

#[test]
fun init_ok() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<State>();
        assert_eq!(state.owner(), ADMIN);
        assert_eq!(state.paused(), false);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun init_messenger_cap_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ALICE);
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        state.init_messenger_cap(msg_cap, scenario.ctx());
    };
    abort
}

#[test]
fun init_messenger_cap_ok() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        state.init_messenger_cap(msg_cap, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun register_oapp_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ALICE);
    abort
}

#[test]
fun register_oapp_ok() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    scenario.next_tx(ADMIN);
    {
        let _mc = scenario.take_shared<MessagingChannel>();
        test_scenario::return_shared(_mc);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_oapp_info_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_oapp_info(&mut scenario, ALICE, vector::empty());
    abort
}

#[test]
fun set_oapp_info_ok() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_oapp_info(&mut scenario, ADMIN, vector::empty());
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_peer_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ALICE, 123, vector::empty());
    abort
}

#[test]
fun set_peer_ok() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe");
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_paused_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    set_paused(&mut scenario, ALICE, true);
    abort
}

#[test]
fun set_paused_ok() {
    let mut scenario = init_messenger_oapp();
    set_paused(&mut scenario, ADMIN, true);
    scenario.end();
}

fun send_mint_budget(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    dst_eid: u32,
    amount: u64,
): (Call<SendParam, MessagingReceipt>, SendContext) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let mut my_oapp = scenario.take_shared<OApp>();
        let (_call, _send_ctx) = state.send_mint_budget(
            &mut mt_state,
            &mut my_oapp,
            dst_eid,
            vector::empty(),
            coin::zero<SUI>(scenario.ctx()),
            option::none(),
            amount,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
        (_call, _send_ctx)
    }
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun send_mint_budget_not_operator() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    let (_call, _send_ctx) = send_mint_budget(&mut scenario, ALICE, 123, 100);
    abort
}

#[test]
fun send_mint_budget_ok() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe");

    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        mt_state.set_mint_budget(10000);
        test_scenario::return_shared(mt_state);
    };

    let (_call, _send_ctx) = send_mint_budget(&mut scenario, ADMIN, 123, 100);
    destroy(_call);
    destroy(_send_ctx);
    scenario.end();
}

// #[test]
fun lz_receive_mint_budget_ok() {
    let eid = 123;
    let peer = b"peer_peer_peer_peer_peer_peer_pe";
    let guid = b"guid_guid_guid_guid_guid_guid_gu";
    let nonce = 0;

    // prettier-ignore
    let msg_data = vector[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34,
    ];

    let mut scenario = init_messenger_oapp();
    let _clock = clock::create_for_testing(scenario.ctx());
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, eid, peer);
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<State>();
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let my_oapp = scenario.take_shared<OApp>();

        let endpoint = scenario.take_shared<EndpointV2>();
        let executor_cap = call_cap::new_individual_cap(scenario.ctx());
        let mut msg_channel = scenario.take_shared<MessagingChannel>();

        // endpoint.set_receive_library(
        //     state.call_cap(),
        //     @0x1234, // receiver
        //     eid, // src_eid
        //     @0x5678, // new_lib
        //     0, // grace_period
        //     &_clock,
        // );

        // endpoint.verify(
        //     &executor_cap,
        //     &mut msg_channel,
        //     eid,
        //     bytes32::from_bytes(peer), // sender
        //     nonce, // nonce
        //     bytes32::from_bytes(guid), // payload_hash
        //     &_clock,
        // );

        let receive_call = endpoint.lz_receive(
            &executor_cap,
            &mut msg_channel,
            eid, // src_eid
            bytes32::from_bytes(peer), // sender
            nonce, // nonce
            bytes32::from_bytes(guid), // guid
            msg_data, // msg
            b"extra_data", // extra_data
            option::none(), // value
            scenario.ctx(),
        );

        state.lz_receive(
            &mut mt_state,
            &my_oapp,
            receive_call,
            scenario.ctx(),
        );

        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
        test_scenario::return_shared(msg_channel);
        destroy(executor_cap);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}
