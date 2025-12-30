#[test_only]
module mtoken::mtoken_cc_tests;

use mtoken::message_codec;
use mtoken::mt::{Self, MT as XAUM};
use mtoken::mtoken::{Self, MessengerCap};
use sui::clock;
use sui::coin::{Self, Coin};
use sui::test_scenario;

// constants are not exported, so we need to redefine them here
const INIT_DELAY: u64 = 5;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;

fun init_xaum(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(SYS);
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    scenario
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun cc_new_messenger_cap_err_not_owner() {
    let mut scenario = init_xaum();
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
    };
    abort
}

#[test]
fun cc_new_messenger_cap_ok() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<MessengerCap>();
        scenario.return_to_sender(cap);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_send_mint_budget_err_not_operator() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_send_mint_budget(&mut state, &msg_cap, 100, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_send_mint_budget_err_invalid_messenger_cap() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN); // issue a new messenger cap
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_send_mint_budget(&mut state, &msg_cap, 100, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun cc_send_mint_budget_err_not_enough() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_send_mint_budget(&mut state, &msg_cap, 100, scenario.ctx());
        test_scenario::return_shared(msg_cap);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test]
fun cc_send_mint_budget_ok() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::set_mint_budget(&mut state, 10000);
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_send_mint_budget(&mut state, &msg_cap, 100, scenario.ctx());
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_send_token_err_invalid_messenger_cap() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN); // issue a new messenger cap
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_send_token(
            &mut state,
            &msg_cap,
            ADMIN,
            b"BOB",
            coin::zero<XAUM>(scenario.ctx()),
            scenario.ctx(),
        );
    };
    abort
}

#[test]
fun cc_send_token_ok() {
    let mut scenario = init_xaum();
    let mut _clock = clock::create_for_testing(scenario.ctx());

    // mint
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.set_mint_budget(10000);
        mtoken::request_mint_to(&state, ALICE, 100, &_clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
    _clock.increment_for_testing(INIT_DELAY * 1000);
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let req = scenario.take_shared<mtoken::MintReq>();
        mtoken::execute_mint_to(&mut state, req, &_clock, scenario.ctx());
        test_scenario::return_shared(state);
    };

    // new messenger cap
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };

    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        let token = scenario.take_from_sender<Coin<XAUM>>();
        mtoken::cc_send_token(
            &mut state,
            &msg_cap,
            ADMIN,
            b"Alice",
            token,
            scenario.ctx(),
        );
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EInvalidMessengerCap)]
fun cc_receive_err_invalid_messenger_cap() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN); // issue a new messenger cap
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ALICE, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_receive(&mut state, &msg_cap, b"msg", scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = message_codec::EInvalidMessageLength)]
fun cc_receive_err_invalid_message() {
    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_receive(&mut state, &msg_cap, b"msg", scenario.ctx());
    };
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

    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_receive(&mut state, &msg_cap, msg, scenario.ctx());
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };

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

    let mut scenario = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::cc_new_messenger_cap(&mut state, ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        mtoken::cc_receive(&mut state, &msg_cap, msg, scenario.ctx());
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
    };

    scenario.end();
}
