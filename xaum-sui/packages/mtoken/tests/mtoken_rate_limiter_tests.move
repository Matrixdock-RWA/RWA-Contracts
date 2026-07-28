#[test_only]
module mtoken::mtoken_rate_limiter_tests;

use mtoken::message_codec;
use mtoken::mt::{Self, MT as XAUM};
use mtoken::mtoken::{Self, MessengerCap};
use mtoken::mtoken_gov;
use mtoken::mtoken_rate_limiter;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::deny_list::{Self, DenyList};
use sui::event;
use sui::test_scenario;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

// constants are not exported, so we need to redefine them here
const MIN_DELAY: u64 = 3600;
const MIN_GOV_DELAY: u64 = 3600 * 24;

fun init_xaum(): (test_scenario::Scenario, Clock) {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    let _clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), 0);
    };
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.cc_new_messenger_cap(ADMIN, scenario.ctx());
        test_scenario::return_shared(state);
    };
    (scenario, _clock)
}

fun cc_receive_token(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    sender: address,
    receiver: address,
    amount: u64,
    clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let msg_cap = scenario.take_from_sender<MessengerCap>();
        let deny_list = scenario.take_shared<DenyList>();
        let msg = message_codec::encode_cc_token_message(sender, receiver.to_bytes(), amount);
        let (_receiver, opt) = state.cc_receive_v2(
            &msg_cap,
            msg,
            &deny_list,
            clock,
            scenario.ctx(),
        );
        opt.destroy_none();
        scenario.return_to_sender(msg_cap);
        test_scenario::return_shared(state);
        test_scenario::return_shared(deny_list);
    };
}

fun add_rate_limiter(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    amount: u64,
    window_seconds: u64,
    _clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.add_rate_limiter(amount, window_seconds, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun remove_rate_limiter(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.remove_rate_limiter();
        test_scenario::return_shared(state);
    };
}

fun set_rate_limit(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    amount: u64,
    window_seconds: u64,
    _clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.set_rate_limit(amount, window_seconds, _clock);
        test_scenario::return_shared(state);
    };
}

fun set_single_msg_limit(scenario: &mut test_scenario::Scenario, caller: address, limit: u64) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.set_single_msg_limit(limit);
        test_scenario::return_shared(state);
    };
}

fun add_to_whitelist(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    sender: vector<u8>,
    receiver: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.add_to_rate_limiter_whitelist(sender, receiver);
        test_scenario::return_shared(state);
    };
}

fun remove_from_whitelist(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    sender: vector<u8>,
    receiver: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.remove_from_rate_limiter_whitelist(sender, receiver, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun cc_process_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    msg_id: u64,
    clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.cc_process_rate_limited_msg(msg_id, clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun cc_discard_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    msg_id: u64,
    clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.cc_discard_rate_limited_msg(msg_id, clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_cc_process_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    msg_id: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.revoke_cc_process_rate_limited_msg(msg_id, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_cc_discard_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    msg_id: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.revoke_cc_discard_rate_limited_msg(msg_id, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun set_gov_delay(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    new_gov_delay: u64,
    clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_gov_delay(&mut state, new_gov_delay, clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun set_delay(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    new_delay: u64,
    clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_delay(&mut state, new_delay, clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

// raise gov_delay then delay above their initial (zero) values so cc_process/cc_discard
// actually queue a pending request instead of executing immediately. Raising gov_delay
// itself executes in one call (clock is at t=0, and its OWN timelock uses the *current*
// gov_delay, which is still 0). set_delay, however, is governed by gov_delay (not by
// `delay` itself) — so once gov_delay is raised, the first set_delay call only registers
// a pending request; advance the clock past the new gov_delay and call it again to finish.
fun raise_delay(scenario: &mut test_scenario::Scenario, clock: &mut Clock, new_delay: u64) {
    set_gov_delay(scenario, ADMIN, MIN_GOV_DELAY, clock);
    set_delay(scenario, ADMIN, new_delay, clock);
    clock.increment_for_testing(MIN_GOV_DELAY * 1000);
    set_delay(scenario, ADMIN, new_delay, clock);
}

fun check_has_rate_limiter(scenario: &mut test_scenario::Scenario, isSet: bool) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.has_rate_limiter(), isSet);
        test_scenario::return_shared(state);
    }
}

fun check_rate_limit(scenario: &mut test_scenario::Scenario, limit: u64, window: u64) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        let (_limit, _window) = state.rate_limit();
        assert_eq!(_limit, limit);
        assert_eq!(_window, window);
        test_scenario::return_shared(state);
    }
}

fun check_single_msg_limit(scenario: &mut test_scenario::Scenario, expected: u64) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.single_msg_limit(), expected);
        test_scenario::return_shared(state);
    }
}

fun check_is_in_whitelist(
    scenario: &mut test_scenario::Scenario,
    sender: vector<u8>,
    receiver: address,
    expected: bool,
) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.is_in_whitelist(sender, receiver), expected);
        test_scenario::return_shared(state);
    }
}

fun check_amount_can_be_received(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    in_flight: u64,
    capacity: u64,
) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        let (_in_flight, _capacity) = state.amount_can_be_received(_clock);
        assert_eq!(_in_flight, in_flight);
        assert_eq!(_capacity, capacity);
        test_scenario::return_shared(state);
    }
}

fun check_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    msg_id: u64,
    sender: vector<u8>,
    receiver: address,
    amount: u64,
) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        let (_sender, _receiver, _amount) = state.rate_limited_msg(msg_id);
        assert_eq!(_sender, sender);
        assert_eq!(_receiver, receiver);
        assert_eq!(_amount, amount);
        test_scenario::return_shared(state);
    }
}

fun check_has_rate_limited_msg(
    scenario: &mut test_scenario::Scenario,
    msg_id: u64,
    is_queued: bool,
) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.has_rate_limited_msg(msg_id), is_queued);
        test_scenario::return_shared(state);
    }
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun add_rate_limiter_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ALICE, 100, 3600, &_clock);
    abort
}

#[test]
fun add_rate_limiter_ok() {
    let (mut scenario, _clock) = init_xaum();
    check_has_rate_limiter(&mut scenario, false);
    add_rate_limiter(&mut scenario, ADMIN, 12345, 1200, &_clock);
    check_has_rate_limiter(&mut scenario, true);
    check_rate_limit(&mut scenario, 12345, 1200);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EPendingMsgsExist)]
fun remove_rate_limiter_err_pending_msgs() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 123, 1200, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 456, &_clock);
    remove_rate_limiter(&mut scenario, ADMIN);
    abort
}

#[test]
fun remove_rate_limiter_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 12345, 1200, &_clock);
    check_has_rate_limiter(&mut scenario, true);
    remove_rate_limiter(&mut scenario, ADMIN);
    check_has_rate_limiter(&mut scenario, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_rate_limit_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 123, 456, &_clock);
    set_rate_limit(&mut scenario, ADMIN, 10000, 3600, &_clock);
    check_rate_limit(&mut scenario, 10000, 3600);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun rate_limit_consume() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // receive 1000 -> minted
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 1000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 1000, 9000);

    // receive 2000 -> minted
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 2000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 3000, 7000);

    // receive 3000 -> minted
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 6000, 4000);

    // receive 5000 -> rate-limited, queued (6000 + 5000 > 10000)
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 5000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 6000, 4000);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun rate_limit_recover() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // receive 8000 -> minted; in_flight = 8000, capacity = 2000
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 8000, 2000);

    // +360s: decay = 360 * 10000 / 3600 = 1000 -> in_flight = 7000
    _clock.increment_for_testing(360 * 1000);
    check_amount_can_be_received(&mut scenario, &_clock, 7000, 3000);

    // +720s (total 1080s): decay = 3000 -> in_flight = 5000
    _clock.increment_for_testing(720 * 1000);
    check_amount_can_be_received(&mut scenario, &_clock, 5000, 5000);

    // +1080s (total 2160s): decay = 6000 -> in_flight = 2000
    _clock.increment_for_testing(1080 * 1000);
    check_amount_can_be_received(&mut scenario, &_clock, 2000, 8000);

    // +1800s (total 3960s): decay = 11000 > 8000 -> in_flight = 0, fully recovered
    _clock.increment_for_testing(1800 * 1000);
    check_amount_can_be_received(&mut scenario, &_clock, 0, 10000);

    // receive 3000 -> minted; in_flight = 3000, capacity = 7000
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 3000, 7000);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun rate_limited_msg_queue() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // receive 8000 -> minted; in_flight = 8000, capacity = 2000
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);

    // receive 3000 -> rate-limited (8000 + 3000 > 10000), queued as msg_id=0
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    assert_eq!(event::num_events(), 1);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgAddedEvent>().pop_back();
    check_rate_limited_msg(&mut scenario, 0, ALICE.to_bytes(), BOB, 3000);

    // receive 4000 -> rate-limited, queued as msg_id=1
    cc_receive_token(&mut scenario, ADMIN, BOB, ALICE, 4000, &_clock);
    assert_eq!(event::num_events(), 1);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgAddedEvent>().pop_back();
    check_rate_limited_msg(&mut scenario, 1, BOB.to_bytes(), ALICE, 4000);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_process_rate_limited_msg_err_not_operator() {
    let (mut scenario, _clock) = init_xaum();
    cc_process_rate_limited_msg(&mut scenario, ALICE, 123, &_clock);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_discard_rate_limited_msg_err_not_operator() {
    let (mut scenario, _clock) = init_xaum();
    cc_discard_rate_limited_msg(&mut scenario, ALICE, 123, &_clock);
    abort
}

// closes the delay-bypass where an operator could pre-register a request against a
// msg_id that doesn't hold a message yet, let it mature in advance, and instantly
// deliver/discard whatever real message eventually lands there
#[test, expected_failure(abort_code = mtoken::ERateLimitedMsgNotFound)]
fun cc_process_rate_limited_msg_err_not_found() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERateLimitedMsgNotFound)]
fun cc_discard_rate_limited_msg_err_not_found() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    abort
}

#[test]
fun cc_process_rate_limited_msg_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // setup: receive 8000 (minted to BOB), queue msg#0 (alice→bob 3000), queue msg#1 (bob→alice 4000)
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, BOB, ALICE, 4000, &_clock);

    // process msg#1 -> mints 4000 to ALICE
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 1, &_clock);
    // 3 events: RateLimitedMsgRemovedEvent, CCReceiveTokenEvent, RateLimitedMsgProcessedEvent
    assert_eq!(event::num_events(), 3);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgRemovedEvent>().pop_back();
    event::events_by_type<mtoken::CCReceiveTokenEvent>().pop_back();
    event::events_by_type<mtoken::ProcessRateLimitedMsgEffectedEvent>().pop_back();

    // msg#1 removed, msg#0 still queued; total_supply = 8000 (BOB) + 4000 (ALICE) = 12000
    check_has_rate_limited_msg(&mut scenario, 0, true);
    check_has_rate_limited_msg(&mut scenario, 1, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun cc_discard_rate_limited_msg_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // setup: receive 8000 (minted to BOB), queue msg#0 (alice→bob 3000), queue msg#1 (bob→alice 4000)
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, BOB, ALICE, 4000, &_clock);

    // discard msg#1 -> no minting
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 1, &_clock);
    // 2 events: RateLimitedMsgRemovedEvent, RateLimitedMsgDiscardedEvent
    assert_eq!(event::num_events(), 2);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgRemovedEvent>().pop_back();
    event::events_by_type<mtoken::DiscardRateLimitedMsgEffectedEvent>().pop_back();

    // msg#1 removed, msg#0 still queued; total_supply = 8000 only (nothing minted for discarded msg)
    check_has_rate_limited_msg(&mut scenario, 0, true);
    check_has_rate_limited_msg(&mut scenario, 1, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

// ===== delayed cc_process/cc_discard (non-zero delay) tests =====

#[test]
fun cc_process_rate_limited_msg_delayed_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);

    // queue msg#0 (alice->bob 3000): 8000 fills capacity, 3000 overflows
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);

    // first call only registers a pending request; message stays queued, nothing minted
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    assert_eq!(event::num_events(), 1);
    event::events_by_type<mtoken::ProcessRateLimitedMsgRequestEvent>().pop_back();
    check_has_rate_limited_msg(&mut scenario, 0, true);

    // advance past the delay; second call matures and executes
    _clock.increment_for_testing(MIN_DELAY * 1000);
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    assert_eq!(event::num_events(), 3);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgRemovedEvent>().pop_back();
    event::events_by_type<mtoken::CCReceiveTokenEvent>().pop_back();
    event::events_by_type<mtoken::ProcessRateLimitedMsgEffectedEvent>().pop_back();
    check_has_rate_limited_msg(&mut scenario, 0, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun cc_process_rate_limited_msg_revoke_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);

    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock); // queued as #0

    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock); // creates a pending request
    revoke_cc_process_rate_limited_msg(&mut scenario, ADMIN, 0);
    // revoking only destroys the pending request; the queued message itself is untouched
    check_has_rate_limited_msg(&mut scenario, 0, true);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun cc_process_rate_limited_msg_revoke_err_not_owner_or_revoker() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    revoke_cc_process_rate_limited_msg(&mut scenario, ALICE, 0);
    abort
}

#[test]
fun cc_discard_rate_limited_msg_delayed_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);

    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock); // queued as #0

    // first call only registers a pending request; message stays queued
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    assert_eq!(event::num_events(), 1);
    event::events_by_type<mtoken::DiscardRateLimitedMsgRequestEvent>().pop_back();
    check_has_rate_limited_msg(&mut scenario, 0, true);

    // advance past the delay; second call matures and executes
    _clock.increment_for_testing(MIN_DELAY * 1000);
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    assert_eq!(event::num_events(), 2);
    event::events_by_type<mtoken_rate_limiter::RateLimitedMsgRemovedEvent>().pop_back();
    event::events_by_type<mtoken::DiscardRateLimitedMsgEffectedEvent>().pop_back();
    check_has_rate_limited_msg(&mut scenario, 0, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun cc_discard_rate_limited_msg_revoke_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);

    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock); // queued as #0

    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock); // creates a pending request
    revoke_cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0);
    check_has_rate_limited_msg(&mut scenario, 0, true);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun cc_discard_rate_limited_msg_revoke_err_not_owner_or_revoker() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock);
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    revoke_cc_discard_rate_limited_msg(&mut scenario, ALICE, 0);
    abort
}

// closes the delay-bypass where a "process" request registered against a msg_id, but never
// executed (the message is instead consumed via the independent "discard" path), would
// otherwise survive as a stale-but-matured entry; if the rate limiter is later removed and
// re-added (resetting msg_id numbering) and a brand new message reuses that same msg_id, the
// stale request must not still be there to let it execute instantly with no delay applied.
#[test]
fun cc_process_rate_limited_msg_stale_request_cleared_by_discard() {
    let (mut scenario, mut _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    raise_delay(&mut scenario, &mut _clock, MIN_DELAY);

    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock); // queued as #0

    // register a "process" request for msg#0, but never let it mature/execute
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);

    // instead, msg#0 is consumed via the independent "discard" path
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock); // registers a discard request
    _clock.increment_for_testing(MIN_DELAY * 1000);
    cc_discard_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock); // matures & executes

    // queue is now empty: the rate limiter can be removed and a fresh one added, which
    // resets msg_id numbering back to 0
    remove_rate_limiter(&mut scenario, ADMIN);
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);

    // a brand new message reuses msg_id=0 in the fresh limiter
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 8000, &_clock);
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 3000, &_clock); // queued as #0 again

    // if the stale "process" request had survived, this would execute instantly (et == 0);
    // it must instead only register a fresh pending request
    cc_process_rate_limited_msg(&mut scenario, ADMIN, 0, &_clock);
    assert_eq!(event::num_events(), 1);
    event::events_by_type<mtoken::ProcessRateLimitedMsgRequestEvent>().pop_back();
    check_has_rate_limited_msg(&mut scenario, 0, true);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

// ===== single_msg_limit tests =====

#[test]
fun set_single_msg_limit_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 123, 456, &_clock);
    check_single_msg_limit(&mut scenario, 0);
    set_single_msg_limit(&mut scenario, ADMIN, 5000);
    check_single_msg_limit(&mut scenario, 5000);
    // disable again
    set_single_msg_limit(&mut scenario, ADMIN, 0);
    check_single_msg_limit(&mut scenario, 0);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun single_msg_limit_blocks_large_msg() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    set_single_msg_limit(&mut scenario, ADMIN, 3000);

    // 2000 <= 3000: passes single msg limit and rate limit -> minted
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 2000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 2000, 8000);

    // 4000 > 3000: blocked by single msg limit -> queued as msg#0
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 4000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 2000, 8000); // unchanged
    check_has_rate_limited_msg(&mut scenario, 0, true);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun single_msg_limit_disabled_when_zero() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    // single_msg_limit = 0 (disabled): any amount passes if window allows

    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 9000, &_clock);
    check_amount_can_be_received(&mut scenario, &_clock, 9000, 1000);
    // no messages queued
    check_has_rate_limited_msg(&mut scenario, 0, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

// ===== whitelist tests =====

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun remove_from_whitelist_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 123, 456, &_clock);
    remove_from_whitelist(&mut scenario, ALICE, ALICE.to_bytes(), BOB);
    abort
}

#[test]
fun update_whitelist_ok() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 123, 456, &_clock);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    add_to_whitelist(&mut scenario, ADMIN, ALICE.to_bytes(), BOB);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, true);
    // removing from whitelist
    remove_from_whitelist(&mut scenario, ADMIN, ALICE.to_bytes(), BOB);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun whitelist_bypasses_rate_limit() {
    let (mut scenario, _clock) = init_xaum();
    // tight rate limit: only 100 per window
    add_rate_limiter(&mut scenario, ADMIN, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, ADMIN, ALICE.to_bytes(), BOB);

    // whitelisted: 9999 passes despite the tiny rate limit window
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 9999, &_clock);
    // in_flight unchanged (whitelist bypasses rate limiter update)
    check_amount_can_be_received(&mut scenario, &_clock, 0, 100);
    // no queued messages
    check_has_rate_limited_msg(&mut scenario, 0, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun whitelist_bypasses_single_msg_limit() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 10000, 3600, &_clock);
    set_single_msg_limit(&mut scenario, ADMIN, 100);
    add_to_whitelist(&mut scenario, ADMIN, ALICE.to_bytes(), BOB);

    // whitelisted: 9999 > single_msg_limit=100 but still passes
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 9999, &_clock);
    check_has_rate_limited_msg(&mut scenario, 0, false);

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun whitelist_is_pair_specific() {
    let (mut scenario, _clock) = init_xaum();
    add_rate_limiter(&mut scenario, ADMIN, 100, 3600, &_clock);
    // only (ALICE -> BOB) is whitelisted, not (BOB -> ALICE)
    add_to_whitelist(&mut scenario, ADMIN, ALICE.to_bytes(), BOB);

    // ALICE->BOB: whitelisted, passes
    cc_receive_token(&mut scenario, ADMIN, ALICE, BOB, 9999, &_clock);
    check_has_rate_limited_msg(&mut scenario, 0, false);

    // BOB->ALICE: not whitelisted, hits rate limit -> queued
    cc_receive_token(&mut scenario, ADMIN, BOB, ALICE, 9999, &_clock);
    check_has_rate_limited_msg(&mut scenario, 0, true);

    clock::destroy_for_testing(_clock);
    scenario.end();
}
