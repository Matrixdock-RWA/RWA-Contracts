#[test_only]
module mtoken::mtoken_cc_tests;

use mtoken::message_codec;
use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken::{Self, MessengerCap};
use std::unit_test::{assert_eq, destroy};
use sui::coin::{Self, Coin};
use sui::deny_list::{Self, DenyList};
use sui::test_scenario;

// constants are not exported, so we need to redefine them here
const INIT_DELAY: u64 = 5;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;

fun init_xagm(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    scenario
}

fun new_messenger_cap(scenario: &mut test_scenario::Scenario, caller: address, holder: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.cc_new_messenger_cap(holder, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun set_mint_budget(scenario: &mut test_scenario::Scenario, caller: address, amount: u64) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.set_mint_budget(amount);
        test_scenario::return_shared(state);
    };
}

fun send_mint_budget(scenario: &mut test_scenario::Scenario, caller: address, amount: u64) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        state.cc_send_mint_budget(&msg_cap, amount, scenario.ctx());
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };
}

fun receive_msg(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    msg: vector<u8>,
): (address, Option<Coin<XAGM>>) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        let _deny_list = scenario.take_shared<DenyList>();
        let (_receiver, _opt) = state.cc_receive(&msg_cap, msg, &_deny_list, scenario.ctx());
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
        test_scenario::return_shared(_deny_list);
        (_receiver, _opt)
    }
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun cc_new_messenger_cap_err_not_owner() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ALICE, ALICE);
    abort
}

#[test]
fun cc_new_messenger_cap_ok() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ALICE);
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<MessengerCap>();
        scenario.return_to_sender(cap);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_send_mint_budget_err_not_operator() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ALICE);
    send_mint_budget(&mut scenario, ALICE, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_send_mint_budget_err_invalid_messenger_cap() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    new_messenger_cap(&mut scenario, ADMIN, ALICE); // issue a new messenger cap
    send_mint_budget(&mut scenario, ADMIN, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun cc_send_mint_budget_err_not_enough() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    send_mint_budget(&mut scenario, ADMIN, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::EZeroValue)]
fun cc_send_mint_budget_err_zero_value() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    send_mint_budget(&mut scenario, ADMIN, 0);
    abort
}

#[test]
fun cc_send_mint_budget_ok() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    set_mint_budget(&mut scenario, ADMIN, 10000);
    send_mint_budget(&mut scenario, ADMIN, 100);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_send_token_err_invalid_messenger_cap() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    new_messenger_cap(&mut scenario, ADMIN, ALICE); // issue a new messenger cap
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        state.cc_send_token(
            &msg_cap,
            ADMIN,
            b"BOB",
            coin::zero<XAGM>(scenario.ctx()),
            scenario.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EZeroValue)]
fun cc_send_token_err_zero_value() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ALICE);
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        let token = coin::zero<XAGM>(scenario.ctx());
        state.cc_send_token(
            &msg_cap,
            ADMIN,
            b"Alice",
            token,
            scenario.ctx(),
        );
    };
    abort
}

#[test]
fun cc_send_token_ok() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ALICE);

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let token = state.mint_for_testing(10000, scenario.ctx());
        transfer::public_transfer(token, ALICE);
        test_scenario::return_shared(state);
    };

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        let token = scenario.take_from_sender<Coin<XAGM>>();
        state.cc_send_token(
            &msg_cap,
            ADMIN,
            b"Alice",
            token,
            scenario.ctx(),
        );
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_receive_err_invalid_messenger_cap() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    new_messenger_cap(&mut scenario, ADMIN, ALICE); // issue a new messenger cap
    let (_receiver, _opt) = receive_msg(&mut scenario, ADMIN, b"msg");
    abort
}

#[test, expected_failure(abort_code = message_codec::EInvalidMessageLength)]
fun cc_receive_err_invalid_message() {
    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    let (_receiver, _opt) = receive_msg(&mut scenario, ADMIN, b"msg");
    abort
}

#[test]
fun cc_receive_token_ok() {
    // prettier-ignore
    let msg = vector[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xe0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x60,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xa0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x22,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, // sender
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0B, 0x0B, // receiver
    ];

    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    let (_receiver, opt) = receive_msg(&mut scenario, ADMIN, msg);
    opt.destroy_none();
    scenario.end();
}

#[test]
fun cc_receive_blocked_token_ok() {
    // prettier-ignore
    let msg = vector[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xe0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x60,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xa0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x22, // amount
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 9, 8, 7, 6, 5, // sender
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0B, 0x0B, // receiver
    ];

    let mut scenario = init_xagm();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        state.add_to_blocked_list(@0xB0B, &mut _deny_list, scenario.ctx());
        test_scenario::return_shared(state);
        test_scenario::return_shared(_deny_list);
    };

    scenario.next_epoch(ADMIN);
    let (receiver, opt) = receive_msg(&mut scenario, ADMIN, msg);
    assert_eq!(receiver, @0xB0B);
    assert_eq!(opt.is_some(), true);
    let token = opt.destroy_some();
    assert_eq!(token.balance().value(), 0x22);
    destroy(token);
    scenario.end();
}

#[test]
fun cc_receive_mint_budget_ok() {
    // prettier-ignore
    let msg = vector[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34,
    ];

    let mut scenario = init_xagm();
    new_messenger_cap(&mut scenario, ADMIN, ADMIN);
    let (_receiver, opt) = receive_msg(&mut scenario, ADMIN, msg);
    opt.destroy_none();
    scenario.end();
}
