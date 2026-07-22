#[test_only]
module mtoken::mtoken_gov_tests;

use mtoken::mt::{Self, MT as XAUM};
use mtoken::mtoken::{Self, MessengerCap};
use mtoken::mtoken_gov;
use std::unit_test::assert_eq;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, CoinMetadata};
use sui::deny_list::{Self, DenyList};
use sui::event;
use sui::test_scenario;
use sui::url;

// constants are not exported, so we need to redefine them here
// const VERSION: u64 = 3;
const INIT_DELAY: u64 = 5;
const INIT_GOV_DELAY: u64 = 5;
const MIN_DELAY: u64 = 3600;
const MAX_DELAY: u64 = 3600 * 48;
const MIN_GOV_DELAY: u64 = 3600 * 24;
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const OPERATOR: address = @0x0EA7;
const REVOKER: address = @0xE0E0;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

fun init_xaum(): (test_scenario::Scenario, Clock) {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    let mut _clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };

    // init operator & revoker
    set_operator(&mut scenario, &_clock, ADMIN, OPERATOR);
    set_revoker(&mut scenario, &_clock, ADMIN, REVOKER);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_operator(&mut scenario, &_clock, ADMIN, OPERATOR);
    accept_revoker(&mut scenario, &_clock, REVOKER);

    (scenario, _clock)
}

fun set_gov_delay(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_gov_delay: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_gov_delay(&mut state, new_gov_delay, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_gov_delay(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_gov_delay(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_gov_delay(scenario: &mut test_scenario::Scenario, caller: address, gov_delay: u64) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.gov_delay(), gov_delay);
        test_scenario::return_shared(state);
    };
}

// raise gov_delay from its initial test value (INIT_GOV_DELAY) so that
// set_delay can pass the new_delay <= gov_delay cross-check
fun effect_gov_delay(
    scenario: &mut test_scenario::Scenario,
    _clock: &mut Clock,
    new_gov_delay: u64,
) {
    set_gov_delay(scenario, _clock, ADMIN, new_gov_delay);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_gov_delay(scenario, _clock, ADMIN, new_gov_delay);
    check_gov_delay(scenario, ADMIN, new_gov_delay);
}

fun set_delay(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_delay: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_delay(&mut state, new_delay, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_delay(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_delay(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_delay(scenario: &mut test_scenario::Scenario, caller: address, delay: u64) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.delay(), delay);
        test_scenario::return_shared(state);
    };
}

fun set_operator(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_operator: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_operator(&mut state, new_operator, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_operator(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_operator(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_operator(scenario: &mut test_scenario::Scenario, operator: address) {
    scenario.next_tx(operator);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.operator(), operator);
        test_scenario::return_shared(state);
    };
}

fun set_revoker(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_revoker: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_revoker(&mut state, new_revoker, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun accept_revoker(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::accept_revoker(&mut state, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_set_revoker(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_revoker(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_revoker(scenario: &mut test_scenario::Scenario, revoker: address) {
    scenario.next_tx(revoker);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.revoker(), revoker);
        test_scenario::return_shared(state);
    };
}

fun pause(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::pause(&mut state, &mut _deny_list, scenario.ctx());
        test_scenario::return_shared(_deny_list);
        test_scenario::return_shared(state);
    };
}

fun unpause(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken_gov::unpause(&mut state, &mut _deny_list, _clock, scenario.ctx());
        test_scenario::return_shared(_deny_list);
        test_scenario::return_shared(state);
    };
}

fun revoke_unpause(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_unpause(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun disable_cc_send(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken::disable_cc_send(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun enable_cc_send(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::enable_cc_send(&mut state, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_enable_cc_send(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_enable_cc_send(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_cc_send_disabled(scenario: &mut test_scenario::Scenario, expected: bool) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.is_cc_send_disabled(), expected);
        test_scenario::return_shared(state);
    };
}

fun new_messenger_cap(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    holder: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::new_messenger_cap(&mut state, holder, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_new_messenger_cap(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_new_messenger_cap(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_messenger_cap(scenario: &mut test_scenario::Scenario, holder: address) {
    scenario.next_tx(holder);
    {
        let cap = scenario.take_from_sender<MessengerCap>();
        scenario.return_to_sender(cap);
    };
}

fun setup_rate_limiter(
    scenario: &mut test_scenario::Scenario,
    amount: u64,
    window_seconds: u64,
    _clock: &Clock,
) {
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        state.add_rate_limiter(amount, window_seconds, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun remove_rate_limiter(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::remove_rate_limiter(&mut state, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_remove_rate_limiter(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_remove_rate_limiter(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_has_rate_limiter(scenario: &mut test_scenario::Scenario, expected: bool) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(mtoken::has_rate_limiter(&state), expected);
        test_scenario::return_shared(state);
    };
}

fun set_rate_limit(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    amount: u64,
    window_seconds: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_rate_limit(&mut state, amount, window_seconds, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_set_rate_limit(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_rate_limit(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_rate_limit(scenario: &mut test_scenario::Scenario, amount: u64, window_seconds: u64) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        let (_amount, _window) = state.rate_limit();
        assert_eq!(_amount, amount);
        assert_eq!(_window, window_seconds);
        test_scenario::return_shared(state);
    };
}

fun add_to_whitelist(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    sender: vector<u8>,
    receiver: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::add_to_rate_limiter_whitelist(
            &mut state,
            sender,
            receiver,
            _clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
    };
}

fun revoke_add_to_whitelist(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_add_to_whitelist(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
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
        assert_eq!(mtoken::is_in_whitelist(&state, sender, receiver), expected);
        test_scenario::return_shared(state);
    };
}

fun set_single_msg_limit(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    limit: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::set_single_msg_limit(&mut state, limit, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun revoke_set_single_msg_limit(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_single_msg_limit(&mut state, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_single_msg_limit(scenario: &mut test_scenario::Scenario, limit: u64) {
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAUM>>();
        assert_eq!(state.single_msg_limit(), limit);
        test_scenario::return_shared(state);
    };
}

// === set_gov_delay tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_gov_delay_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ALICE, MIN_GOV_DELAY);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::EDelayTooShort)]
fun set_gov_delay_err_too_short() {
    let (mut scenario, _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY - 1);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::EDelayTooLong)]
fun set_gov_delay_err_too_long() {
    let (mut scenario, _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MAX_GOV_DELAY + 1);
    abort
}

// cross-check: gov_delay may not go below the current delay
#[test, expected_failure(abort_code = mtoken_gov::EDelayTooShort)]
fun set_gov_delay_err_less_than_delay() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MAX_DELAY);
    // raise delay to MAX_DELAY (2 days)
    set_delay(&mut scenario, &_clock, ADMIN, MAX_DELAY);
    _clock.increment_for_testing(MAX_DELAY * 1000);
    set_delay(&mut scenario, &_clock, ADMIN, MAX_DELAY);
    check_delay(&mut scenario, ADMIN, MAX_DELAY);
    // MIN_GOV_DELAY (1 day) is within bounds but below the current delay
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_gov_delay_err_not_effective() {
    let (mut scenario, mut _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 123);
    _clock.increment_for_testing(INIT_GOV_DELAY * 500);
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 123);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_gov_delay_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 123);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 321);
    abort
}

#[test]
fun set_gov_delay_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 100);
    check_gov_delay(&mut scenario, ADMIN, INIT_GOV_DELAY);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 100);
    check_gov_delay(&mut scenario, ADMIN, MIN_GOV_DELAY + 100);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_gov_delay_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_gov_delay(&mut scenario, ALICE);
    abort
}

// revoke_request is idempotent — revoking with no pending request is a no-op
#[test]
fun set_gov_delay_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAUM>>();
        mtoken_gov::revoke_set_gov_delay(&mut state, scenario.ctx());
        mtoken_gov::revoke_set_gov_delay(&mut state, scenario.ctx());
        // no RequestRevokedEvent emitted for a no-op revoke
        assert_eq!(event::num_events(), 0);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_gov_delay_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 1);
    revoke_set_gov_delay(&mut scenario, ADMIN);
    check_gov_delay(&mut scenario, ADMIN, INIT_GOV_DELAY);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_gov_delay_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_gov_delay(&mut scenario, &_clock, ADMIN, MIN_GOV_DELAY + 1);
    revoke_set_gov_delay(&mut scenario, REVOKER);
    check_gov_delay(&mut scenario, ADMIN, INIT_GOV_DELAY);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === set_delay tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_delay_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_delay(&mut scenario, &_clock, ALICE, 1234);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::EDelayTooShort)]
fun set_delay_err_too_short() {
    let (mut scenario, _clock) = init_xaum();
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY-1);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::EDelayTooLong)]
fun set_delay_err_too_long() {
    let (mut scenario, _clock) = init_xaum();
    set_delay(&mut scenario, &_clock, ADMIN, MAX_DELAY+1);
    abort
}

// cross-check: delay may not exceed the current gov_delay
#[test, expected_failure(abort_code = mtoken_gov::EDelayTooLong)]
fun set_delay_err_greater_than_gov_delay() {
    let (mut scenario, _clock) = init_xaum();
    // gov_delay is still INIT_GOV_DELAY (5s), so any valid delay exceeds it
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_delay_err_not_effective() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+123);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+123);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_delay_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY + 123);
    _clock.increment_for_testing(MIN_GOV_DELAY * 1000);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY + 321);
    abort
}

#[test]
fun set_delay_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+100);
    check_delay(&mut scenario, ADMIN, INIT_DELAY);
    _clock.increment_for_testing(MIN_GOV_DELAY * 1000);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+100);
    check_delay(&mut scenario, ADMIN, MIN_DELAY+100);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_delay_revoke_err_not_owner_or_revoker() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY);
    revoke_set_delay(&mut scenario, ALICE);
    abort
}

#[test]
fun set_delay_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_delay(&mut scenario, ADMIN);
    revoke_set_delay(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_delay_revoke_by_owner_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+1);
    revoke_set_delay(&mut scenario, ADMIN);
    check_delay(&mut scenario, ADMIN, INIT_DELAY);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_delay_revoke_by_revoker_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    effect_gov_delay(&mut scenario, &mut _clock, MIN_GOV_DELAY);
    set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+1);
    revoke_set_delay(&mut scenario, REVOKER);
    check_delay(&mut scenario, ADMIN, INIT_DELAY);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === set_operator tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_operator_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_operator_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_operator_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_operator(&mut scenario, &_clock, ADMIN, BOB);
    abort
}

#[test]
fun set_operator_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    check_operator(&mut scenario, OPERATOR);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    check_operator(&mut scenario, ALICE);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_operator_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_operator(&mut scenario, ALICE);
    abort
}

#[test]
fun set_operator_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_operator(&mut scenario, ADMIN);
    revoke_set_operator(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_operator_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_operator(&mut scenario, ADMIN);
    check_operator(&mut scenario, OPERATOR);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_operator_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_operator(&mut scenario, REVOKER);
    check_operator(&mut scenario, OPERATOR);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === set_revoker tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_revoker_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_revoker_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_revoker_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_revoker(&mut scenario, &_clock, ADMIN, BOB);
    abort
}

// Owner cannot execute the pending request via set_revoker — only the new
// revoker can, via accept_revoker.
#[test, expected_failure(abort_code = mtoken_gov::ENotNewRevoker)]
fun set_revoker_err_not_new_revoker() {
    let (mut scenario, mut _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ENoPendingRequest)]
fun accept_revoker_err_no_pending_request() {
    let (mut scenario, _clock) = init_xaum();
    accept_revoker(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun accept_revoker_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    accept_revoker(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun accept_revoker_err_wrong_sender() {
    let (mut scenario, mut _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    accept_revoker(&mut scenario, &_clock, BOB);
    abort
}

#[test]
fun set_revoker_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    check_revoker(&mut scenario, REVOKER);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    accept_revoker(&mut scenario, &_clock, ALICE);
    check_revoker(&mut scenario, ALICE);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrOperator)]
fun set_revoker_revoke_err_not_owner_or_operator() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_revoker(&mut scenario, ALICE);
    abort
}

#[test]
fun set_revoker_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_revoker(&mut scenario, ADMIN);
    revoke_set_revoker(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_revoker_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_revoker(&mut scenario, ADMIN);
    check_revoker(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_revoker_revoke_by_operator_ok() {
    let (mut scenario, _clock) = init_xaum();
    set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_revoker(&mut scenario, OPERATOR);
    check_revoker(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === unpause tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun unpause_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    unpause(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun unpause_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    unpause(&mut scenario, &_clock, ADMIN);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ENotPaused)]
fun unpause_err_not_paused() {
    let (mut scenario, _clock) = init_xaum();
    // cannot pre-plant an unpause request while not paused
    unpause(&mut scenario, &_clock, ADMIN);
    abort
}

// a new pause revokes a pending (even matured) unpause request,
// so it cannot be used to bypass the delay of a later emergency pause
#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun pause_revokes_pending_unpause() {
    let (mut scenario, mut _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN); // queue request
    _clock.increment_for_testing(INIT_DELAY * 1000); // request matures

    pause(&mut scenario, OPERATOR); // new incident: matured request must not survive
    unpause(&mut scenario, &_clock, ADMIN); // re-queues instead of effecting
    unpause(&mut scenario, &_clock, ADMIN); // still within delay -> aborts
    abort
}

#[test]
fun pause_then_full_delay_unpause_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    _clock.increment_for_testing(INIT_DELAY * 1000);

    pause(&mut scenario, OPERATOR); // revokes the matured request
    unpause(&mut scenario, &_clock, ADMIN); // fresh request
    _clock.increment_for_testing(INIT_DELAY * 1000); // full delay again
    unpause(&mut scenario, &_clock, ADMIN); // effected
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun unpause_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    unpause(&mut scenario, &_clock, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun unpause_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    revoke_unpause(&mut scenario, ALICE);
    abort
}

#[test]
fun unpause_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_unpause(&mut scenario, ADMIN);
    revoke_unpause(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun unpause_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    revoke_unpause(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun unpause_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    pause(&mut scenario, OPERATOR);
    unpause(&mut scenario, &_clock, ADMIN);
    revoke_unpause(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === enable_cc_send tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun enable_cc_send_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    enable_cc_send(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun enable_cc_send_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ECCSendNotDisabled)]
fun enable_cc_send_err_not_disabled() {
    let (mut scenario, _clock) = init_xaum();
    // cannot pre-plant an enable request while cc-send is not disabled
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    abort
}

// a new disable revokes a pending (even matured) enable request,
// so it cannot be used to bypass the delay of a later emergency disable
#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun disable_cc_send_revokes_pending_enable() {
    let (mut scenario, mut _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN); // queue request
    _clock.increment_for_testing(INIT_DELAY * 1000); // request matures

    disable_cc_send(&mut scenario, OPERATOR); // new incident: matured request must not survive
    enable_cc_send(&mut scenario, &_clock, ADMIN); // re-queues instead of effecting
    enable_cc_send(&mut scenario, &_clock, ADMIN); // still within delay -> aborts
    abort
}

#[test]
fun disable_then_full_delay_enable_cc_send_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    _clock.increment_for_testing(INIT_DELAY * 1000);

    disable_cc_send(&mut scenario, OPERATOR); // revokes the matured request
    enable_cc_send(&mut scenario, &_clock, ADMIN); // fresh request
    _clock.increment_for_testing(INIT_DELAY * 1000); // full delay again
    enable_cc_send(&mut scenario, &_clock, ADMIN); // effected
    check_cc_send_disabled(&mut scenario, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun enable_cc_send_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    check_cc_send_disabled(&mut scenario, true);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    check_cc_send_disabled(&mut scenario, true);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    check_cc_send_disabled(&mut scenario, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun enable_cc_send_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    revoke_enable_cc_send(&mut scenario, ALICE);
    abort
}

#[test]
fun enable_cc_send_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_enable_cc_send(&mut scenario, ADMIN);
    revoke_enable_cc_send(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun enable_cc_send_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    revoke_enable_cc_send(&mut scenario, ADMIN);
    check_cc_send_disabled(&mut scenario, true);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun enable_cc_send_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    disable_cc_send(&mut scenario, OPERATOR);
    enable_cc_send(&mut scenario, &_clock, ADMIN);
    revoke_enable_cc_send(&mut scenario, REVOKER);
    check_cc_send_disabled(&mut scenario, true);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === new_messenger_cap tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun new_messenger_cap_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun new_messenger_cap_err_not_effective() {
    let (mut scenario, mut _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 500);
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun new_messenger_cap_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    new_messenger_cap(&mut scenario, &_clock, ADMIN, BOB);
    abort
}

#[test]
fun new_messenger_cap_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    check_messenger_cap(&mut scenario, ALICE);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun new_messenger_cap_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_new_messenger_cap(&mut scenario, ALICE);
    abort
}

#[test]
fun new_messenger_cap_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_new_messenger_cap(&mut scenario, ADMIN);
    revoke_new_messenger_cap(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun new_messenger_cap_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_new_messenger_cap(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun new_messenger_cap_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    new_messenger_cap(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_new_messenger_cap(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === remove_rate_limiter tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun remove_rate_limiter_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    remove_rate_limiter(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun remove_rate_limiter_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    abort
}

#[test]
fun remove_rate_limiter_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    check_has_rate_limiter(&mut scenario, true);
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    check_has_rate_limiter(&mut scenario, true);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    check_has_rate_limiter(&mut scenario, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun remove_rate_limiter_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    revoke_remove_rate_limiter(&mut scenario, ALICE);
    abort
}

#[test]
fun remove_rate_limiter_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_remove_rate_limiter(&mut scenario, ADMIN);
    revoke_remove_rate_limiter(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun remove_rate_limiter_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    revoke_remove_rate_limiter(&mut scenario, ADMIN);
    check_has_rate_limiter(&mut scenario, true);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun remove_rate_limiter_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    remove_rate_limiter(&mut scenario, &_clock, ADMIN);
    revoke_remove_rate_limiter(&mut scenario, REVOKER);
    check_has_rate_limiter(&mut scenario, true);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === add_to_whitelist tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun add_to_whitelist_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    add_to_whitelist(&mut scenario, &_clock, ALICE, ALICE.to_bytes(), BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ENoRateLimiter)]
fun add_to_whitelist_err_no_rate_limiter() {
    let (mut scenario, _clock) = init_xaum();
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun add_to_whitelist_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun add_to_whitelist_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, BOB.to_bytes(), ALICE);
    abort
}

#[test]
fun add_to_whitelist_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, true);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun add_to_whitelist_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    revoke_add_to_whitelist(&mut scenario, ALICE);
    abort
}

#[test]
fun add_to_whitelist_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_add_to_whitelist(&mut scenario, ADMIN);
    revoke_add_to_whitelist(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun add_to_whitelist_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    revoke_add_to_whitelist(&mut scenario, ADMIN);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun add_to_whitelist_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    add_to_whitelist(&mut scenario, &_clock, ADMIN, ALICE.to_bytes(), BOB);
    revoke_add_to_whitelist(&mut scenario, REVOKER);
    check_is_in_whitelist(&mut scenario, ALICE.to_bytes(), BOB, false);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === set_rate_limit tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_rate_limit_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_rate_limit(&mut scenario, &_clock, ALICE, 100, 3600);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ENoRateLimiter)]
fun set_rate_limit_err_no_rate_limiter() {
    let (mut scenario, _clock) = init_xaum();
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_rate_limit_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_rate_limit_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 200, 3600);
    abort
}

#[test]
fun set_rate_limit_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 500, 7200);
    check_rate_limit(&mut scenario, 100, 3600);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 500, 7200);
    check_rate_limit(&mut scenario, 500, 7200);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_rate_limit_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    revoke_set_rate_limit(&mut scenario, ALICE);
    abort
}

#[test]
fun set_rate_limit_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_rate_limit(&mut scenario, ADMIN);
    revoke_set_rate_limit(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_rate_limit_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    revoke_set_rate_limit(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_rate_limit_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_rate_limit(&mut scenario, &_clock, ADMIN, 100, 3600);
    revoke_set_rate_limit(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === set_single_msg_limit tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_single_msg_limit_err_not_owner() {
    let (mut scenario, _clock) = init_xaum();
    set_single_msg_limit(&mut scenario, &_clock, ALICE, 5000);
    abort
}

#[test, expected_failure(abort_code = mtoken_gov::ENoRateLimiter)]
fun set_single_msg_limit_err_no_rate_limiter() {
    let (mut scenario, _clock) = init_xaum();
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_single_msg_limit_err_not_effective() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    abort
}

#[test, expected_failure(abort_code = mtoken::ERequestArgsMismatch)]
fun set_single_msg_limit_err_args_mismatch() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 9999);
    abort
}

#[test]
fun set_single_msg_limit_ok() {
    let (mut scenario, mut _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    check_single_msg_limit(&mut scenario, 0);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    check_single_msg_limit(&mut scenario, 5000);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_single_msg_limit_revoke_err_not_owner_or_revoker() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    revoke_set_single_msg_limit(&mut scenario, ALICE);
    abort
}

#[test]
fun set_single_msg_limit_revoke_no_req_ok() {
    let (mut scenario, _clock) = init_xaum();
    revoke_set_single_msg_limit(&mut scenario, ADMIN);
    revoke_set_single_msg_limit(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_single_msg_limit_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    revoke_set_single_msg_limit(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_single_msg_limit_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xaum();
    setup_rate_limiter(&mut scenario, 100, 3600, &_clock);
    set_single_msg_limit(&mut scenario, &_clock, ADMIN, 5000);
    revoke_set_single_msg_limit(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}
