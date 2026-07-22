#[test_only]
module messenger_lz::messenger_oapp_tests;

use call::call::Call;
use call::call_cap;
use endpoint_v2::endpoint_send::SendParam;
use endpoint_v2::endpoint_v2::{Self, EndpointV2};
use endpoint_v2::messaging_channel::MessagingChannel;
use endpoint_v2::messaging_receipt::MessagingReceipt;
use messenger_lz::messenger_oapp::{Self, State, SendContext};
use messenger_lz::ptb_builder;
use mtoken::mtoken::{Self, State as MtState, MessengerCap};
use mtoken::mtoken_gov;
use oapp::oapp::OApp;
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::deny_list::{Self, DenyList};
use sui::sui::SUI;
use sui::test_scenario;
use utils::bytes32;
use utils::package;
use xaum::xaum::{Self, XAUM};

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

fun init_messenger_oapp(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
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
        let lz_receive_info = vector[];
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

fun set_oapp_info(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let mut endpoint = scenario.take_shared<EndpointV2>();
        state.set_oapp_info(
            &my_oapp,
            &mut endpoint,
            b"next_nonce_info",
            b"lz_receive_info",
            b"extra_info",
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
    }
}

fun skip(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    src_eid: u32,
    sender: vector<u8>,
    nonce: u64,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let endpoint = scenario.take_shared<EndpointV2>();
        let mut channel = scenario.take_shared<MessagingChannel>();
        state.skip(&my_oapp, &endpoint, &mut channel, src_eid, sender, nonce, scenario.ctx());
        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
        test_scenario::return_shared(channel);
    }
}

fun set_peer(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    eid: u32,
    peer: vector<u8>,
    addr_len: u8,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<State>();
        let mut my_oapp = scenario.take_shared<OApp>();
        let endpoint = scenario.take_shared<EndpointV2>();
        let mut channel = scenario.take_shared<MessagingChannel>();

        state.set_peer(
            &mut my_oapp,
            &endpoint,
            &mut channel,
            eid,
            peer,
            addr_len,
            scenario.ctx(),
        );

        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
        test_scenario::return_shared(channel);
    }
}

fun set_enforced_options(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    eid: u32,
    msg_type: u16,
    options: vector<u8>,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let mut my_oapp = scenario.take_shared<OApp>();
        state.set_enforced_options(&mut my_oapp, eid, msg_type, options, scenario.ctx());
        test_scenario::return_shared(state);
        test_scenario::return_shared(my_oapp);
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
        let _clock = clock::create_for_testing(scenario.ctx());
        mtoken_gov::new_messenger_cap(&mut mt_state, holder, &_clock, scenario.ctx());
        mtoken_gov::new_messenger_cap(&mut mt_state, holder, &_clock, scenario.ctx());
        test_scenario::return_shared(mt_state);
        clock::destroy_for_testing(_clock);
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
            vector[],
            coin::zero<SUI>(scenario.ctx()),
            amount,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
        (_call, _send_ctx)
    }
}

fun send_token(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    dst_eid: u32,
    token: Coin<XAUM>,
    receiver: vector<u8>,
): (Call<SendParam, MessagingReceipt>, SendContext) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<State>();
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let mut my_oapp = scenario.take_shared<OApp>();
        let (_call, _send_ctx) = state.send_token(
            &mut mt_state,
            &mut my_oapp,
            dst_eid,
            vector[],
            coin::zero<SUI>(scenario.ctx()),
            receiver,
            token,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
        (_call, _send_ctx)
    }
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
fun set_send_library_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let mut endpoint = scenario.take_shared<EndpointV2>();
        state.set_send_library(&my_oapp, &mut endpoint, 123, @0x456, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_receive_library_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let mut endpoint = scenario.take_shared<EndpointV2>();
        let _clock = clock::create_for_testing(scenario.ctx());
        state.set_receive_library(
            &my_oapp,
            &mut endpoint,
            123, // src_eid
            @0x456, // new_lib
            0, // grace_period
            &_clock,
            scenario.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_config_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<State>();
        let my_oapp = scenario.take_shared<OApp>();
        let endpoint = scenario.take_shared<EndpointV2>();
        let _call = state.set_config(
            &my_oapp,
            &endpoint,
            @0x123, // lib
            0x456, // eid
            3, // config_type
            vector[], // config
            scenario.ctx(),
        );
    };
    abort
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
    set_oapp_info(&mut scenario, ALICE);
    abort
}

#[test]
fun set_oapp_info_ok() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_oapp_info(&mut scenario, ADMIN);
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun skip_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    skip(&mut scenario, ALICE, 123, b"sender", 456);
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_peer_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ALICE, 123, vector[], 20);
    abort
}

#[test]
fun set_peer_ok() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe", 20);
    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::ENotOwner)]
fun set_enforced_options_err_not_owner() {
    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_enforced_options(&mut scenario, ALICE, 123, 1, vector[]);
    abort
}

#[test]
fun set_enforced_options_ok() {
    // prettier-ignore
    // 0x000301001101000000000000000000000000000493e0
    let options = vector[
        0x00, 0x03, 0x01, 0x00, 0x11, 0x01, 0x00, 0x00, 0x00, 
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
        0x00, 0x04, 0x93, 0xe0
    ];

    let mut scenario = init_messenger_oapp();
    register_oapp(&mut scenario, ADMIN);
    set_enforced_options(&mut scenario, ADMIN, 123, 456, options);
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

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun send_mint_budget_not_operator() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    let (_call, _send_ctx) = send_mint_budget(&mut scenario, ALICE, 123, 100);
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::EPaused)]
fun send_mint_budget_err_paused() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    set_paused(&mut scenario, ADMIN, true);
    let (_call, _send_ctx) = send_mint_budget(&mut scenario, ALICE, 123, 100);
    abort
}

#[test]
fun send_mint_budget_ok() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe", 20);

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

#[test]
fun send_token_ok() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe", 20);

    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(200, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let (_call, _send_ctx) = send_token(
            &mut scenario,
            ADMIN,
            123,
            token,
            b"receiver_receiver_re", // 20 bytes
        );
        destroy(_call);
        destroy(_send_ctx);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = messenger_oapp::EPaused)]
fun send_token_err_paused() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    set_paused(&mut scenario, ADMIN, true);

    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(200, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let (_call, _send_ctx) = send_token(
            &mut scenario,
            ADMIN,
            123,
            token,
            b"receiver_receiver_re22", // 22 bytes
        );
    };
    abort
}

#[test, expected_failure(abort_code = messenger_oapp::EReceiverLen)]
fun send_token_err_receiver_len_mismatch() {
    let mut scenario = init_messenger_oapp();
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);
    register_oapp(&mut scenario, ADMIN);
    set_peer(&mut scenario, ADMIN, 123, b"peer_peer_peer_peer_peer_peer_pe", 20);

    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(200, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let (_call, _send_ctx) = send_token(
            &mut scenario,
            ADMIN,
            123,
            token,
            b"receiver_receiver_re22", // 22 bytes
        );
    };
    abort
}

#[test]
fun lz_receive_info_ok() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<State>();
        let mt_state = scenario.take_shared<MtState<XAUM>>();
        let my_oapp = scenario.take_shared<OApp>();
        let info = ptb_builder::lz_receive_info(&state, &mt_state, &my_oapp);
        std::debug::print(&info);
        std::debug::print(&package::package_of_type<State>());

        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
    };
    scenario.end();
}

// TODO: fix this test
#[test, expected_failure]
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
    set_peer(&mut scenario, ADMIN, eid, peer, 20);
    create_new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    init_messenger_cap(&mut scenario, ADMIN);

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
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

        let _deny_list = scenario.take_shared<DenyList>();
        state.lz_receive_v2(
            &mut mt_state,
            &my_oapp,
            receive_call,
            &_deny_list,
            &_clock,
            scenario.ctx(),
        );

        test_scenario::return_shared(state);
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(my_oapp);
        test_scenario::return_shared(endpoint);
        test_scenario::return_shared(msg_channel);
        test_scenario::return_shared(_deny_list);
        destroy(executor_cap);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun handle_cc_receive_ok() {
    let mut scenario = init_messenger_oapp();

    // normal case
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<State>();
        state.handle_cc_receive_for_testing(ALICE, option::none());
        assert_eq!(state.blocked_amount(ALICE), 0);
        test_scenario::return_shared(state);
    };

    // blocked case
    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(100, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let mut state = scenario.take_shared<State>();
        state.handle_cc_receive_for_testing(BOB, option::some(token));
        assert_eq!(state.blocked_amount(BOB), 100);
        test_scenario::return_shared(state);
    };

    // blocked again
    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(200, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let mut state = scenario.take_shared<State>();
        state.handle_cc_receive_for_testing(BOB, option::some(token));
        assert_eq!(state.blocked_amount(BOB), 300);
        test_scenario::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure]
fun claim_blocked_token_err_no_token() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        state.claim_blocked_token(scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test]
fun claim_blocked_token_ok() {
    let mut scenario = init_messenger_oapp();
    scenario.next_tx(ADMIN);
    {
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        let token = mt_state.mint_for_testing(500, scenario.ctx());
        test_scenario::return_shared(mt_state);

        let mut state = scenario.take_shared<State>();
        state.handle_cc_receive_for_testing(ALICE, option::some(token));
        assert_eq!(state.blocked_amount(ALICE), 500);
        test_scenario::return_shared(state);
    };

    scenario.next_epoch(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        state.claim_blocked_token(scenario.ctx());
        assert_eq!(state.blocked_amount(ALICE), 0);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

/*
// TODO: fix this test
#[test, expected_failure]
fun claim_blocked_token_err_still_blocked() {
    let mut scenario = init_messenger_oapp();

    // add ALICE to blocked list & sent him token
    scenario.next_tx(ADMIN);
    {
        let mut _deny_list = scenario.take_shared<DenyList>();
        let mut mt_state = scenario.take_shared<MtState<XAUM>>();
        mt_state.add_to_blocked_list(ALICE, &mut _deny_list, scenario.ctx());
        let token = mt_state.mint_for_testing(100, scenario.ctx());
        test_scenario::return_shared(mt_state);
        test_scenario::return_shared(_deny_list);
        
        let mut state = scenario.take_shared<State>();
        state.handle_cc_receive_for_testing(ALICE, option::some(token));
        test_scenario::return_shared(state);
    };

    // claim blocked token
    scenario.next_epoch(ALICE);
    {
        let mut state = scenario.take_shared<State>();
        state.claim_blocked_token(scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.end();
}
*/
