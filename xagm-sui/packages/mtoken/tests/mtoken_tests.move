#[test_only]
module mtoken::mtoken_tests;

use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken;
use mtoken::mtoken_gov;
use std::unit_test::assert_eq;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, CoinMetadata};
use sui::deny_list::{Self, DenyList};
use sui::event;
use sui::package::{test_publish, UpgradeCap};
use sui::test_scenario;
use sui::url;

// constants are not exported, so we need to redefine them here
const VERSION: u64 = 4;
const INIT_DELAY: u64 = 5;
const INIT_GOV_DELAY: u64 = 5;
const REQ_TTL: u64 = 3600 * 12;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const OPERATOR: address = @0x0EA7;
const REVOKER: address = @0xE0E0;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

fun init_xagm(): (test_scenario::Scenario, Clock) {
    let mut scenario = test_scenario::begin(SYS);
    let mut _clock = clock::create_for_testing(scenario.ctx());
    deny_list::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    _clock.set_for_testing(1773816560052); // 2026-03-18T06:59:47.036Z

    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        state.init_annual_fee_rate(0, 1000000000, &_clock, scenario.ctx());
        test_scenario::return_shared(state);
    };

    init_operator_and_revoker(&mut scenario, &mut _clock, ADMIN);

    (scenario, _clock)
}

fun init_operator_and_revoker(
    scenario: &mut test_scenario::Scenario,
    _clock: &mut Clock,
    caller: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken_gov::set_operator(&mut state, OPERATOR, _clock, scenario.ctx());
        mtoken_gov::set_revoker(&mut state, REVOKER, _clock, scenario.ctx());
        _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
        mtoken_gov::set_operator(&mut state, OPERATOR, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
    // the new revoker accepts the pending request itself
    scenario.next_tx(REVOKER);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken_gov::accept_revoker(&mut state, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    }
}

fun create_new_state(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
}

fun set_description(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    new_description: vector<u8>,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut metadata = scenario.take_shared<CoinMetadata<XAGM>>();
        mtoken::update_description(
            &state,
            &mut metadata,
            new_description.to_string(),
            scenario.ctx(),
        );
        test_scenario::return_shared(metadata);
        test_scenario::return_shared(state);
    };
}

fun set_icon_url(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    new_icon_url: vector<u8>,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut metadata = scenario.take_shared<CoinMetadata<XAGM>>();
        mtoken::update_icon_url(
            &state,
            &mut metadata,
            new_icon_url.to_ascii_string(),
            scenario.ctx(),
        );
        test_scenario::return_shared(metadata);
        test_scenario::return_shared(state);
    };
}

fun pause(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::pause(&mut state, &mut _deny_list, scenario.ctx());
        test_scenario::return_shared(_deny_list);
        test_scenario::return_shared(state);
    };
}

fun request_set_owner(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_owner: address,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());
        mtoken::request_transfer_ownership(&state, new_owner, upgrade_cap, _clock, scenario.ctx());
        assert_eq!(state.owner(), caller);
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun execute_set_owner(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::TransferOwnershipReq>();
        mtoken::execute_transfer_ownership(&mut state, req, _clock, scenario.ctx());
        assert_eq!(state.owner(), caller);
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_owner(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::TransferOwnershipReq>();
        mtoken::revoke_transfer_ownership(&state, req, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun request_mint_to(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    recipient: address,
    amount: u64,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let oz_per_token = state.oz_per_token(_clock);
        mtoken::request_mint_to(
            &state,
            recipient,
            amount,
            oz_per_token,
            _clock,
            scenario.ctx(),
        );
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun execute_mint_to(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::MintReq>();
        mtoken::execute_mint_to(&mut state, req, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        // assert_eq!(
        //     event::events_by_type<mtoken::MintEvent>().pop_back(),
        //     mtoken::new_mint_event(ALICE, 100, 0, req_id),
        // );
        test_scenario::return_shared(state);
    };
}

fun revoke_mint_to(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::MintReq>();
        mtoken::revoke_mint_to(&state, req, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun redeem(
    scenario: &mut test_scenario::Scenario,
    caller: address,
    to_be_burnt: Coin<XAGM>,
    _clock: &Clock,
) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let oz_per_token = state.oz_per_token(_clock);
        mtoken::redeem(&mut state, to_be_burnt, oz_per_token, _clock, scenario.ctx());
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

#[test]
fun init_ok() {
    let (mut scenario, _clock) = init_xagm();

    // check State fields
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.version(), VERSION);
        assert_eq!(state.owner(), ADMIN);
        assert_eq!(state.operator(), OPERATOR);
        assert_eq!(state.revoker(), REVOKER);
        assert_eq!(state.delay(), INIT_DELAY);
        assert_eq!(state.gov_delay(), INIT_GOV_DELAY);
        assert_eq!(state.mint_budget(), 0);
        assert_eq!(state.is_cc_send_disabled(), false);
        test_scenario::return_shared(state);
    };

    // check metadata
    {
        let (decimals, symbol, name, description) = mt::metadata();
        let metadata = scenario.take_shared<CoinMetadata<XAGM>>();
        assert_eq!(coin::get_decimals(&metadata), decimals);
        assert_eq!(coin::get_name(&metadata), name.to_string());
        assert_eq!(coin::get_symbol(&metadata), symbol.to_ascii_string());
        assert_eq!(coin::get_description(&metadata), description.to_string());
        assert_eq!(coin::get_icon_url(&metadata).is_some(), false);
        // allow_global_pause ?
        test_scenario::return_shared(metadata);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_description_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    set_description(&mut scenario, ALICE, b"new description");
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_icon_url_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    set_icon_url(&mut scenario, ALICE, b"new/icon/url");
    abort
}

#[test]
fun update_metadata_ok() {
    let new_description = b"new description";
    let new_icon_url = b"new/icon/url";
    let (mut scenario, _clock) = init_xagm();

    // update metadata
    set_description(&mut scenario, ADMIN, new_description);
    set_icon_url(&mut scenario, ADMIN, new_icon_url);

    // check metadata
    scenario.next_tx(ALICE);
    {
        let metadata = scenario.take_shared<CoinMetadata<XAGM>>();
        assert_eq!(coin::get_description(&metadata), new_description.to_string());
        assert_eq!(
            coin::get_icon_url(&metadata).extract(),
            url::new_unsafe_from_bytes(new_icon_url),
        );
        test_scenario::return_shared(metadata);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun pause_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    pause(&mut scenario, ALICE);
    abort
}

#[test]
fun pause_ok() {
    let (mut scenario, _clock) = init_xagm();
    pause(&mut scenario, OPERATOR);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_owner_req_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotNewOwner)]
fun set_owner_exec_err_not_new_owner() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_owner(&mut scenario, &_clock, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_owner_exec_err_not_effective() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_owner(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EReqExpired)]
fun set_owner_exec_err_expired() {
    let (mut scenario, mut _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    _clock.increment_for_testing(REQ_TTL * 1000);
    execute_set_owner(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EUpgradeCapInvalid)]
fun set_owner_req_err_upgrade_cap_invalid() {
    let (mut scenario, _clock) = init_xagm();

    // request
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = test_publish(
            state.package_address().to_id(),
            scenario.ctx(),
        );
        mtoken::init_upgrade_cap_id(&mut state, &upgrade_cap, scenario.ctx());

        let upgrade_cap2 = test_publish(object::id_from_address(@0x1234), scenario.ctx());
        mtoken::request_transfer_ownership(&state, ALICE, upgrade_cap2, &_clock, scenario.ctx());
    };
    abort
}

#[test]
fun set_owner_ok() {
    let (mut scenario, mut _clock) = init_xagm();

    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_GOV_DELAY * 1000);
    execute_set_owner(&mut scenario, &_clock, ALICE);

    // check upgrade cap
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.owner(), ALICE);
        assert!(state.upgrade_cap_id().is_some());
        // ALICE (the new owner) now holds the UpgradeCap.
        let cap = scenario.take_from_address<UpgradeCap>(ALICE);
        test_scenario::return_to_address(ALICE, cap);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun set_owner_revoke_err_not_owner() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_owner(&mut scenario, ALICE);
    abort
}

#[test]
fun set_owner_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_owner(&mut scenario, ADMIN);

    // check upgrade cap
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.owner(), ADMIN);
        assert!(state.upgrade_cap_id().is_some());
        // ADMIN (still the owner) got the UpgradeCap back.
        let cap = scenario.take_from_address<UpgradeCap>(ADMIN);
        test_scenario::return_to_address(ADMIN, cap);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun set_owner_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_owner(&mut scenario, REVOKER);

    // owner unchanged; the UpgradeCap is returned to the current owner (ADMIN).
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.owner(), ADMIN);
        assert!(state.upgrade_cap_id().is_some());
        // ADMIN (still the owner) got the UpgradeCap back.
        let cap = scenario.take_from_address<UpgradeCap>(ADMIN);
        test_scenario::return_to_address(ADMIN, cap);
        test_scenario::return_shared(state);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EStateIdMismatch)]
fun set_owner_exec_err_bad_req() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, BOB);
    create_new_state(&mut scenario, ALICE);
    execute_set_owner(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EStateIdMismatch)]
fun set_owner_revoke_err_bad_req() {
    let (mut scenario, _clock) = init_xagm();
    request_set_owner(&mut scenario, &_clock, ADMIN, BOB);
    create_new_state(&mut scenario, ALICE);
    revoke_set_owner(&mut scenario, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun mint_req_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, ALICE, ALICE, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun mint_exec_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);
    execute_mint_to(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun mint_exec_err_not_effective() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun mint_exec_err_budget_not_enough() {
    let (mut scenario, mut _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);
    abort
}

#[test]
fun mint_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);

    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_mint_budget(&mut scenario, ADMIN, 10000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);

    // check supply & balance
    scenario.next_tx(ALICE);
    {
        let _xagm = scenario.take_from_sender<Coin<XAGM>>();
        assert_eq!(_xagm.balance().value(), 100);
        scenario.return_to_sender(_xagm);
    };
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000 - 100);
        assert_eq!(state.total_supply(), 100);
        test_scenario::return_shared(state);
    };
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun mint_twice_ok() {
    let (mut scenario, mut _clock) = init_xagm();
    set_mint_budget(&mut scenario, ADMIN, 1000);

    // mint#1
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);

    scenario.next_tx(ALICE);
    let id1 = scenario.most_recent_id_for_sender<Coin<XAGM>>().extract();
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let _xagm = scenario.take_from_sender<Coin<XAGM>>();
        assert_eq!(state.mint_budget(), 1000 - 100);
        assert_eq!(_xagm.balance().value(), 100);
        test_scenario::return_shared(state);
        scenario.return_to_sender(_xagm);
    };

    // mint#2
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);

    scenario.next_tx(ALICE);
    let id2 = scenario.most_recent_id_for_sender<Coin<XAGM>>().extract();
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let _xagm = scenario.take_from_sender<Coin<XAGM>>();
        assert_eq!(state.mint_budget(), 1000 - 180);
        assert_eq!(_xagm.balance().value(), 80);
        test_scenario::return_shared(state);
        scenario.return_to_sender(_xagm);
    };

    // check all coins
    scenario.next_tx(ALICE);
    {
        let _xagm1 = scenario.take_from_sender_by_id<Coin<XAGM>>(id1);
        let _xagm2 = scenario.take_from_sender_by_id<Coin<XAGM>>(id2);
        assert_eq!(_xagm1.balance().value(), 100);
        assert_eq!(_xagm2.balance().value(), 80);
        scenario.return_to_sender(_xagm1);
        scenario.return_to_sender(_xagm2);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwnerOrRevoker)]
fun mint_revoke_err_not_revoker() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    revoke_mint_to(&mut scenario, ALICE);
    abort
}

#[test]
fun mint_revoke_by_owner_ok() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    revoke_mint_to(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun mint_revoke_by_revoker_ok() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    revoke_mint_to(&mut scenario, REVOKER);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::EStateIdMismatch)]
fun mint_exec_err_bad_req() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    create_new_state(&mut scenario, ALICE);
    execute_mint_to(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EStateIdMismatch)]
fun mint_revok_err_bad_req() {
    let (mut scenario, _clock) = init_xagm();
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 80);
    create_new_state(&mut scenario, ALICE);
    revoke_mint_to(&mut scenario, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun redeem_err_not_operator() {
    let (mut scenario, _clock) = init_xagm();
    let to_be_burnt = coin::from_balance(balance::zero<XAGM>(), scenario.ctx());
    redeem(&mut scenario, ALICE, to_be_burnt, &_clock);
    abort
}

#[test]
fun redeem_ok() {
    let (mut scenario, mut _clock) = init_xagm();

    // mint
    set_mint_budget(&mut scenario, ADMIN, 10000);
    request_mint_to(&mut scenario, &_clock, OPERATOR, OPERATOR, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);

    // burn
    scenario.next_tx(OPERATOR);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _xagm = scenario.take_from_sender<Coin<XAGM>>();
        let to_be_burnt = _xagm.split(30, scenario.ctx());
        let oz_per_token = state.oz_per_token(&_clock);
        mtoken::redeem(
            &mut state,
            to_be_burnt,
            oz_per_token,
            &_clock,
            scenario.ctx(),
        );
        assert_eq!(event::num_events(), 1);
        assert_eq!(
            event::events_by_type<mtoken::RedeemEvent>().pop_back(),
            mtoken::new_redeem_event(OPERATOR, 30),
        );
        scenario.return_to_sender(_xagm);
        test_scenario::return_shared(state);
    };

    // check
    scenario.next_tx(OPERATOR);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.mint_budget(), 10000 - 70);
        assert_eq!(state.total_supply(), 70);
        test_scenario::return_shared(state);

        let _xagm = scenario.take_from_sender<Coin<XAGM>>();
        assert_eq!(_xagm.balance().value(), 70);
        scenario.return_to_sender(_xagm);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun block_err_not_operator() {
    let (mut scenario, mut _clock) = init_xagm();

    // block
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::add_to_blocked_list(&mut state, ALICE, &mut _deny_list, scenario.ctx());
    };
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun unblock_err_not_operator() {
    let (mut scenario, mut _clock) = init_xagm();

    // unblock
    scenario.next_tx(ALICE);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::remove_from_blocked_list(&mut state, ALICE, &mut _deny_list, scenario.ctx());
    };
    abort
}

#[test]
fun block_unblock_ok() {
    let (mut scenario, mut _clock) = init_xagm();

    // block
    scenario.next_tx(OPERATOR);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::add_to_blocked_list(&mut state, ALICE, &mut _deny_list, scenario.ctx());
        assert_eq!(event::num_events(), 2);
        assert_eq!(
            event::events_by_type<mtoken::BlockEvent>().pop_back(),
            mtoken::new_block_event(ALICE),
        );
        assert_eq!(
            coin::deny_list_v2_contains_current_epoch<XAGM>(
                &_deny_list,
                ALICE,
                scenario.ctx(),
            ),
            false,
        );
        assert_eq!(coin::deny_list_v2_contains_next_epoch<XAGM>(&_deny_list, ALICE), true);
        test_scenario::return_shared(state);
        test_scenario::return_shared(_deny_list);
    };

    scenario.next_epoch(ADMIN);
    {
        let mut _deny_list = scenario.take_shared<DenyList>();
        assert_eq!(
            coin::deny_list_v2_contains_current_epoch<XAGM>(
                &_deny_list,
                ALICE,
                scenario.ctx(),
            ),
            true,
        );
        assert_eq!(coin::deny_list_v2_contains_next_epoch<XAGM>(&_deny_list, ALICE), true);
        test_scenario::return_shared(_deny_list);
    };

    // unblock
    scenario.next_tx(OPERATOR);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _deny_list = scenario.take_shared<DenyList>();
        mtoken::remove_from_blocked_list(&mut state, ALICE, &mut _deny_list, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        assert_eq!(
            event::events_by_type<mtoken::UnblockEvent>().pop_back(),
            mtoken::new_unblock_event(ALICE),
        );
        test_scenario::return_shared(state);
        test_scenario::return_shared(_deny_list);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test]
fun transfer_ok() {
    let (mut scenario, mut _clock) = init_xagm();

    // mint
    set_mint_budget(&mut scenario, ADMIN, 10000);
    request_mint_to(&mut scenario, &_clock, OPERATOR, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, OPERATOR);

    // transfer
    scenario.next_tx(ALICE);
    {
        let mut _xagm = scenario.take_from_sender<Coin<XAGM>>();
        let to_be_send = _xagm.split(30, scenario.ctx());
        transfer::public_transfer(to_be_send, BOB);
        scenario.return_to_sender(_xagm);
    };

    // check
    scenario.next_tx(BOB);
    {
        let mut _xagm = scenario.take_from_sender<Coin<XAGM>>();
        assert_eq!(_xagm.balance().value(), 30);
        scenario.return_to_sender(_xagm);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

// #[test, expected_failure]
// fun transfer_err_denied_src() {
//     let (mut scenario, _clock) = init_xagm();
//     let mut _clock = clock::create_for_testing(scenario.ctx());

//     scenario.next_tx(SYS);
//     {
//         deny_list::create_for_test(scenario.ctx());
//     };

//     // mint
//     scenario.next_tx(ADMIN);
//     {
//         let mut state = scenario.take_shared<mtoken::State<XAGM>>();
//         state.set_mint_budget(10000);
//         mtoken::request_mint_to(&state, ALICE, 100, &_clock, scenario.ctx());
//         test_scenario::return_shared(state);
//     };
//     _clock.increment_for_testing(INIT_DELAY * 1000);
//     scenario.next_tx(ADMIN);
//     {
//         let mut state = scenario.take_shared<mtoken::State<XAGM>>();
//         let req = scenario.take_shared<mtoken::MintReq>();
//         mtoken::execute_mint_to(&mut state, req, &_clock, scenario.ctx());
//         test_scenario::return_shared(state);
//     };

//     // add in deny_list
//     scenario.next_tx(ADMIN);
//     {
//         let mut state = scenario.take_shared<mtoken::State<XAGM>>();
//         let mut _deny_list = scenario.take_shared<DenyList>();
//         mtoken::add_to_blocked_list(&mut state, ALICE, &mut _deny_list, scenario.ctx());
//         mtoken::add_to_blocked_list(&mut state, BOB, &mut _deny_list, scenario.ctx());
//         test_scenario::return_shared(state);
//         test_scenario::return_shared(_deny_list);
//     };

//     // transfer
//     scenario.next_epoch(ALICE);
//     {
//         let mut _xagm = scenario.take_from_sender<Coin<XAGM>>();
//         let to_be_send = _xagm.split(30, scenario.ctx());
//         transfer::public_transfer(to_be_send, BOB);
//         scenario.return_to_sender(_xagm);
//     };

//     clock::destroy_for_testing(_clock);
//     scenario.end();
// }
