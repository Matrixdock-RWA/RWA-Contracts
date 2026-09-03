#[test_only]
module mtoken::mtoken_mint_budget_tests;

use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken;
use mtoken::mtoken_gov;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::deny_list::{Self, DenyList};
use sui::event;
use sui::test_scenario;

// constants are not exported, so we need to redefine them here
const INIT_DELAY: u64 = 5;
const INIT_GOV_DELAY: u64 = 5;
const MAX_SRC_TX_HASH_LEN: u64 = 128;

// LayerZero endpoint ids: this chain's own, and another branch chain's
const SUI_EID: u32 = 30101;
const OTHER_EID: u32 = 30102;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const SUBMITTER: address = @0xBEEF;
const ALICE: address = @0xA11CE;

fun src_tx_hash(): vector<u8> {
    x"1122334455667788990011223344556677889900112233445566778899001122"
}

fun init_xagm(): (test_scenario::Scenario, Clock) {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    let _clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    (scenario, _clock)
}

// sets SUBMITTER as mint_budget_submitter, going through the full two-step govDelay flow
fun setup_submitter(scenario: &mut test_scenario::Scenario, _clock: &mut Clock) {
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken_gov::set_mint_budget_submitter(&mut state, SUBMITTER, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken_gov::set_mint_budget_submitter(&mut state, SUBMITTER, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun set_local_eid(scenario: &mut test_scenario::Scenario, caller: address, eid: u32) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::set_local_eid(&mut state, eid, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun set_mint_budget(scenario: &mut test_scenario::Scenario, amount: u64) {
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.set_mint_budget(amount);
        test_scenario::return_shared(state);
    };
}

fun return_mint_budget_to_eth(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    new_total_returned_amount: u64,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::return_mint_budget_to_eth(&mut state, new_total_returned_amount, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun claim_mint_budget_from_eth(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    dst_eid: u32,
    new_total_allocated_amount: u64,
    tx_hash: vector<u8>,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let deny_list = scenario.take_shared<DenyList>();
        mtoken::claim_mint_budget_from_eth(
            &mut state,
            dst_eid,
            new_total_allocated_amount,
            tx_hash,
            &deny_list,
            scenario.ctx(),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(deny_list);
    };
}

// the common happy-path shape: submitter configured, local eid declared
fun claim_ok(scenario: &mut test_scenario::Scenario, new_total_allocated_amount: u64) {
    claim_mint_budget_from_eth(
        scenario,
        SUBMITTER,
        SUI_EID,
        new_total_allocated_amount,
        src_tx_hash(),
    );
}

fun pause(scenario: &mut test_scenario::Scenario) {
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut deny_list = scenario.take_shared<DenyList>();
        mtoken::pause(&mut state, &mut deny_list, scenario.ctx());
        test_scenario::return_shared(state);
        test_scenario::return_shared(deny_list);
    };
}

// === set_local_eid tests ===

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_local_eid_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ALICE, SUI_EID);
    abort
}

#[test, expected_failure(abort_code = mtoken::EZeroValue)]
fun set_local_eid_err_zero_value() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, 0);
    abort
}

// re-declaring the same eid stays allowed once budget has moved; only a change is locked
#[test]
fun set_local_eid_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, OTHER_EID);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 100);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    assert_eq!(
        event::events_by_type<mtoken::SetLocalEidEvent>().pop_back(),
        mtoken::new_set_local_eid_event(SUI_EID),
    );

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.local_eid(), SUI_EID);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ELocalEidLocked)]
fun set_local_eid_err_locked_after_claim() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 100);
    set_local_eid(&mut scenario, ADMIN, OTHER_EID);
    abort
}

#[test, expected_failure(abort_code = mtoken::ELocalEidLocked)]
fun set_local_eid_err_locked_after_return() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    set_mint_budget(&mut scenario, 10000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    set_local_eid(&mut scenario, ADMIN, OTHER_EID);
    abort
}

// === return_mint_budget_to_eth tests ===

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun return_mint_budget_to_eth_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    return_mint_budget_to_eth(&mut scenario, ALICE, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::ELocalEidNotSet)]
fun return_mint_budget_to_eth_err_local_eid_not_set() {
    let (mut scenario, _clock) = init_xagm();
    set_mint_budget(&mut scenario, 10000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    abort
}

// a cumulative total not above the recorded one is a replay and aborts
#[test, expected_failure(abort_code = mtoken::EStaleMintBudgetSubmission)]
fun return_mint_budget_to_eth_err_stale() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    set_mint_budget(&mut scenario, 10000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::EStaleMintBudgetSubmission)]
fun return_mint_budget_to_eth_err_zero_total() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 0);
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun return_mint_budget_to_eth_err_not_enough() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    abort
}

#[test]
fun return_mint_budget_to_eth_ok() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    set_mint_budget(&mut scenario, 10000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000 - 100);
        assert_eq!(state.mint_budget_total_returned_amount(), 100);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// a second call with a larger cumulative total only deducts the delta
#[test]
fun return_mint_budget_to_eth_delta_ok() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    set_mint_budget(&mut scenario, 10000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 300);
    assert_eq!(
        event::events_by_type<mtoken::ReturnMintBudgetToEthEvent>().pop_back(),
        mtoken::new_return_mint_budget_to_eth_event(ADMIN, SUI_EID, 200, 300),
    );

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000 - 300);
        assert_eq!(state.mint_budget_total_returned_amount(), 300);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// returning budget must stay available even while paused (risk-reducing path)
#[test]
fun return_mint_budget_to_eth_ok_when_paused() {
    let (mut scenario, _clock) = init_xagm();
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    set_mint_budget(&mut scenario, 10000);
    pause(&mut scenario);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 100);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000 - 100);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// === claim_mint_budget_from_eth tests ===

#[test, expected_failure(abort_code = mtoken::ENotMintBudgetSubmitter)]
fun claim_mint_budget_from_eth_err_not_submitter() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_mint_budget_from_eth(&mut scenario, ALICE, SUI_EID, 100, src_tx_hash());
    abort
}

#[test, expected_failure(abort_code = mtoken::EPaused)]
fun claim_mint_budget_from_eth_err_paused() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    pause(&mut scenario);
    // no epoch advance: the pause must bite in the very next transaction
    claim_ok(&mut scenario, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::ELocalEidNotSet)]
fun claim_mint_budget_from_eth_err_local_eid_not_set() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    claim_ok(&mut scenario, 100);
    abort
}

// a submission prepared for another branch chain must not be taken for this chain's own
#[test, expected_failure(abort_code = mtoken::EWrongTargetChain)]
fun claim_mint_budget_from_eth_err_wrong_target_chain() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_mint_budget_from_eth(&mut scenario, SUBMITTER, OTHER_EID, 100, src_tx_hash());
    abort
}

#[test, expected_failure(abort_code = mtoken::EInvalidSrcTxHash)]
fun claim_mint_budget_from_eth_err_empty_src_tx_hash() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_mint_budget_from_eth(&mut scenario, SUBMITTER, SUI_EID, 100, vector[]);
    abort
}

#[test, expected_failure(abort_code = mtoken::EInvalidSrcTxHash)]
fun claim_mint_budget_from_eth_err_src_tx_hash_too_long() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    let mut too_long = vector[];
    (MAX_SRC_TX_HASH_LEN + 1).do!(|_| too_long.push_back(0xAB));
    claim_mint_budget_from_eth(&mut scenario, SUBMITTER, SUI_EID, 100, too_long);
    abort
}

// the longest identifier a submission must carry is Solana's 64-byte signature; the bound
// itself is what is pinned here
#[test]
fun claim_mint_budget_from_eth_max_src_tx_hash_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    let mut max_len = vector[];
    MAX_SRC_TX_HASH_LEN.do!(|_| max_len.push_back(0xAB));
    claim_mint_budget_from_eth(&mut scenario, SUBMITTER, SUI_EID, 100, max_len);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 100);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun claim_mint_budget_from_eth_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 100);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 100);
        assert_eq!(state.mint_budget_total_allocated_amount(), 100);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// a second call with a larger cumulative total only credits the delta
#[test]
fun claim_mint_budget_from_eth_delta_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 100);
    claim_ok(&mut scenario, 300);
    assert_eq!(
        event::events_by_type<mtoken::ClaimMintBudgetFromEthEvent>().pop_back(),
        mtoken::new_claim_mint_budget_from_eth_event(
            SUBMITTER,
            SUI_EID,
            200,
            300,
            src_tx_hash(),
        ),
    );

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 300);
        assert_eq!(state.mint_budget_total_allocated_amount(), 300);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

// a duplicate cumulative total is a replay and aborts rather than crediting twice
#[test, expected_failure(abort_code = mtoken::EStaleMintBudgetSubmission)]
fun claim_mint_budget_from_eth_err_duplicate() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 300);
    claim_ok(&mut scenario, 300);
    abort
}

#[test, expected_failure(abort_code = mtoken::EStaleMintBudgetSubmission)]
fun claim_mint_budget_from_eth_err_stale() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 300);
    claim_ok(&mut scenario, 100);
    abort
}

// the two watermarks advance independently: returning budget never lowers the allocated total,
// so a later claim still diffs against the full cumulative grant
#[test]
fun claim_and_return_watermarks_independent_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    setup_submitter(&mut scenario, &mut _clock);
    set_local_eid(&mut scenario, ADMIN, SUI_EID);
    claim_ok(&mut scenario, 1000);
    return_mint_budget_to_eth(&mut scenario, ADMIN, 400);
    claim_ok(&mut scenario, 1500);

    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 1500 - 400);
        assert_eq!(state.mint_budget_total_allocated_amount(), 1500);
        assert_eq!(state.mint_budget_total_returned_amount(), 400);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}
