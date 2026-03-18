#[test_only]
module mtoken::mtoken_dilution_tests;

use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken;
use std::unit_test::assert_eq;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario::{Self, Scenario};

// constants
const INIT_DELAY: u64 = 5;
const SECONDS_PER_DAY: u64 = 24 * 3600;
const DAYS_PER_YEAR: u64 = 365;
const OZ_RATIO_BASE: u64 = 1000000000;
const MAX_ANNUAL_FEE_RATE: u64 = 100000000;
const CURRENT_TIME_MS: u64 = 1772160118554; // 2026-02-27T02:42:13.192Z
const CURRENT_DAY_START_TIME: u64 = 1772150400; // 2026-02-27T00:00:00.000Z
const INIT_ANNUAL_FEE_RATE: u64 = MAX_ANNUAL_FEE_RATE/10;
const INIT_OZ_PER_TOKEN_BASE: u64 = OZ_RATIO_BASE-10;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
// const BOB: address = @0xB0B;

fun init_xagm(): (Scenario, Clock) {
    let mut scenario = test_scenario::begin(SYS);
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };

    let mut _clock = clock::create_for_testing(scenario.ctx());
    _clock.set_for_testing(CURRENT_TIME_MS);

    (scenario, _clock)
}

fun init_xagm_with_fee_rate(): (Scenario, Clock) {
    let (mut scenario, _clock) = init_xagm();
    init_annual_fee_rate(
        &mut scenario,
        &_clock,
        ADMIN,
        INIT_ANNUAL_FEE_RATE,
        INIT_OZ_PER_TOKEN_BASE,
    );
    (scenario, _clock)
}

fun init_annual_fee_rate(
    scenario: &mut Scenario,
    _clock: &clock::Clock,
    caller: address,
    annual_fee_rate: u64,
    oz_per_token_base: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.init_annual_fee_rate(annual_fee_rate, oz_per_token_base, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun update_annual_fee_rate(
    scenario: &mut Scenario,
    _clock: &clock::Clock,
    caller: address,
    annual_fee_rate: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.update_annual_fee_rate(annual_fee_rate, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun cc_send_mint_budget_manually(scenario: &mut Scenario, caller: address, amount: u64) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.cc_send_mint_budget_manually(amount, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun cc_receive_mint_budget_manually(scenario: &mut Scenario, caller: address, amount: u64) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.cc_receive_mint_budget_manually(amount, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

#[test]
fun init_ok() {
    let (mut scenario, _clock) = init_xagm();

    // check State fields
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.oz_per_token_base_time(), 0);
        assert_eq!(state.annual_fee_rate(), 0);
        assert_eq!(state.oz_per_token_base(), 0);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun init_annual_fee_rate_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    init_annual_fee_rate(&mut scenario, &_clock, ALICE, 123, 456);
    abort
}

#[test, expected_failure(abort_code = mtoken::EAnnualFeeRateTooLarge)]
fun init_annual_fee_rate_err_annual_fee_rate_too_large() {
    let (mut scenario, _clock) = init_xagm();
    init_annual_fee_rate(&mut scenario, &_clock, ADMIN, MAX_ANNUAL_FEE_RATE+1, 456);
    abort
}

#[test, expected_failure(abort_code = mtoken::EOzPerTokenBaseTooLarge)]
fun init_annual_fee_rate_err_oz_per_token_base_too_large() {
    let (mut scenario, _clock) = init_xagm();
    init_annual_fee_rate(&mut scenario, &_clock, ADMIN, MAX_ANNUAL_FEE_RATE/10, OZ_RATIO_BASE+1);
    abort
}

#[test, expected_failure(abort_code = mtoken::EAnnualFeeRateAlreadyInitialized)]
fun init_annual_fee_rate_err_already_initialized() {
    let (mut scenario, _clock) = init_xagm();
    init_annual_fee_rate(&mut scenario, &_clock, ADMIN, MAX_ANNUAL_FEE_RATE/10, OZ_RATIO_BASE);
    init_annual_fee_rate(&mut scenario, &_clock, ADMIN, MAX_ANNUAL_FEE_RATE/10, OZ_RATIO_BASE);
    abort
}

#[test]
fun init_annual_fee_rate_ok() {
    let (mut scenario, _clock) = init_xagm_with_fee_rate();
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.oz_per_token_base_time(), CURRENT_DAY_START_TIME);
        assert_eq!(state.annual_fee_rate(), INIT_ANNUAL_FEE_RATE);
        assert_eq!(state.oz_per_token_base(), INIT_OZ_PER_TOKEN_BASE);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun update_annual_fee_rate_err_not_owner() {
    let (mut scenario, _clock) = init_xagm_with_fee_rate();
    update_annual_fee_rate(&mut scenario, &_clock, ALICE, 123);
    abort
}

#[test, expected_failure(abort_code = mtoken::EAnnualFeeRateTooLarge)]
fun update_annual_fee_rate_err_too_large() {
    let (mut scenario, _clock) = init_xagm_with_fee_rate();
    update_annual_fee_rate(&mut scenario, &_clock, ADMIN, MAX_ANNUAL_FEE_RATE+1);
    abort
}

#[test, expected_failure(abort_code = mtoken::EAnnualFeeRateNotInitialized)]
fun update_annual_fee_rate_err_not_initialized() {
    let (mut scenario, _clock) = init_xagm();
    update_annual_fee_rate(&mut scenario, &_clock, ADMIN, 123);
    abort
}

#[test]
fun update_annual_fee_rate_ok() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();
    let new_annual_fee_rate = INIT_ANNUAL_FEE_RATE*2;
    _clock.increment_for_testing(SECONDS_PER_DAY * 1000 * 3);
    update_annual_fee_rate(&mut scenario, &_clock, ADMIN, new_annual_fee_rate);

    // check event
    let new_oz_per_token_base = INIT_OZ_PER_TOKEN_BASE - (INIT_ANNUAL_FEE_RATE * 3) / DAYS_PER_YEAR;
    let new_oz_per_token_base_time = CURRENT_DAY_START_TIME + SECONDS_PER_DAY * 3;
    assert_eq!(event::num_events(), 1);
    assert_eq!(
        event::events_by_type<mtoken::UpdateAnnualFeeRateEvent>().pop_back(),
        mtoken::new_update_annual_fee_rate_event(
            new_annual_fee_rate,
            new_oz_per_token_base,
            new_oz_per_token_base_time,
        ),
    );

    // check state
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.annual_fee_rate(), new_annual_fee_rate);
        assert_eq!(state.oz_per_token_base(), new_oz_per_token_base);
        assert_eq!(state.oz_per_token_base_time(), new_oz_per_token_base_time);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_send_mint_budget_manually_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    cc_send_mint_budget_manually(&mut scenario, ALICE, 123);
    abort
}

#[test, expected_failure(abort_code = mtoken::EZeroValue)]
fun cc_send_mint_budget_manually_err_zero_value() {
    let (mut scenario, _clock) = init_xagm();
    cc_send_mint_budget_manually(&mut scenario, ADMIN, 0);
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun cc_send_mint_budget_manually_err_not_enough() {
    let (mut scenario, _clock) = init_xagm();
    cc_send_mint_budget_manually(&mut scenario, ADMIN, 10000);
    abort
}

#[test]
fun cc_send_mint_budget_manually_ok() {
    let (mut scenario, _clock) = init_xagm();
    cc_receive_mint_budget_manually(&mut scenario, ADMIN, 10000);
    cc_send_mint_budget_manually(&mut scenario, ADMIN, 6000);

    // check event
    assert_eq!(event::num_events(), 1);
    assert_eq!(
        event::events_by_type<mtoken::CCSendMintBudgetManuallyEvent>().pop_back(),
        mtoken::new_cc_send_mint_budget_manually_event(6000),
    );

    // check state
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 4000);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun cc_receive_mint_budget_manually_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    cc_receive_mint_budget_manually(&mut scenario, ALICE, 10000);
    abort
}

#[test, expected_failure(abort_code = mtoken::EZeroValue)]
fun cc_receive_mint_budget_manually_err_zero_value() {
    let (mut scenario, _clock) = init_xagm();
    cc_receive_mint_budget_manually(&mut scenario, ADMIN, 0);
    abort
}

#[test]
fun cc_receive_mint_budget_manually_ok() {
    let (mut scenario, _clock) = init_xagm();
    cc_receive_mint_budget_manually(&mut scenario, ADMIN, 10000);

    // check event
    assert_eq!(event::num_events(), 1);
    assert_eq!(
        event::events_by_type<mtoken::CCReceiveMintBudgetManuallyEvent>().pop_back(),
        mtoken::new_cc_receive_mint_budget_manually_event(10000),
    );

    // check state
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EAnnualFeeRateNotInitialized)]
fun oz_per_token_err_not_initialized() {
    let (mut scenario, _clock) = init_xagm();
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        state.oz_per_token(&_clock);
    };
    abort
}

#[test]
fun oz_per_token() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();

    let mut i = 1u64;
    while (i <= 10) {
        _clock.increment_for_testing(SECONDS_PER_DAY * 1000);

        scenario.next_tx(ADMIN);
        {
            let state = scenario.take_shared<mtoken::State<XAGM>>();
            let actual_oz_per_token = state.oz_per_token(&_clock);
            let expected_oz_per_token =
                INIT_OZ_PER_TOKEN_BASE - INIT_ANNUAL_FEE_RATE * i / DAYS_PER_YEAR;
            assert_eq!(actual_oz_per_token, expected_oz_per_token);
            test_scenario::return_shared(state);
        };

        i = i + 1;
    };

    let oz_per_token_base = INIT_OZ_PER_TOKEN_BASE - INIT_ANNUAL_FEE_RATE * 10 / DAYS_PER_YEAR;
    let new_annual_fee_rate = INIT_ANNUAL_FEE_RATE*2;
    update_annual_fee_rate(&mut scenario, &_clock, ADMIN, new_annual_fee_rate);

    i = 1u64;
    while (i <= 20) {
        _clock.increment_for_testing(SECONDS_PER_DAY * 1000);

        scenario.next_tx(ADMIN);
        {
            let state = scenario.take_shared<mtoken::State<XAGM>>();
            let actual_oz_per_token = state.oz_per_token(&_clock);
            let expected_oz_per_token = oz_per_token_base - new_annual_fee_rate * i / DAYS_PER_YEAR;
            assert_eq!(actual_oz_per_token, expected_oz_per_token);
            test_scenario::return_shared(state);
        };

        i = i + 1;
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun get_oz_amount() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();

    let token_amt = 1000_000000000u128;
    let oz_ratio_base = OZ_RATIO_BASE as u128;

    let mut i = 0u64;
    while (i <= 10) {
        i = i + 1;
        _clock.increment_for_testing(SECONDS_PER_DAY * 1000);
        scenario.next_tx(ADMIN);
        {
            let state = scenario.take_shared<mtoken::State<XAGM>>();
            let oz_per_token = state.oz_per_token(&_clock) as u128;
            assert_eq!(
                state.get_oz_amount(token_amt as u64, &_clock) as u128,
                token_amt * oz_per_token / oz_ratio_base,
            );
            test_scenario::return_shared(state);
        }
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EUnexpectedOzPerToken)]
fun request_mint_to_err_unexpected_oz_per_token() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let oz_per_token = state.oz_per_token(&_clock);
        state.request_mint_to(
            ALICE,
            123,
            oz_per_token+1,
            &_clock,
            scenario.ctx(),
        );
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::EUnexpectedOzPerToken)]
fun execute_mint_to_err_unexpected_oz_per_token() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();
    _clock.increment_for_testing(21 * 3600 * 1000);

    // request
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let oz_per_token = state.oz_per_token(&_clock);
        state.request_mint_to(
            ALICE,
            123,
            oz_per_token,
            &_clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
    };

    // execute
    _clock.increment_for_testing(1800 * 1000);
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::MintReq>();
        state.execute_mint_to(req, &_clock, scenario.ctx());
    };

    abort
}

#[test, expected_failure(abort_code = mtoken::EUnexpectedOzPerToken)]
fun redeem_err_unexpected_oz_per_token() {
    let (mut scenario, mut _clock) = init_xagm_with_fee_rate();
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let to_be_burnt = coin::from_balance(balance::zero<XAGM>(), scenario.ctx());
        let oz_per_token = state.oz_per_token(&_clock);
        state.redeem(
            to_be_burnt,
            oz_per_token-1,
            &_clock,
            scenario.ctx(),
        )
    };
    abort
}
