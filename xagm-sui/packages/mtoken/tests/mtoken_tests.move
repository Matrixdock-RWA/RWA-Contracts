#[test_only]
module mtoken::mtoken_tests;

use mtoken::mt::{Self, MT as XAGM};
use mtoken::mtoken;
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
const VERSION: u64 = 2;
const INIT_DELAY: u64 = 5;
const MIN_DELAY: u64 = 3600;
const MAX_DELAY: u64 = 3600 * 48;
const REQ_TTL: u64 = 3600;

// test addresses
const SYS: address = @0x0;
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

fun init_xagm(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(SYS);
    deny_list::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        mt::init_for_testing(scenario.ctx(), INIT_DELAY);
    };
    scenario
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

fun request_set_operator(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_operator: address,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::request_set_operator(&state, new_operator, _clock, scenario.ctx());
        assert_eq!(state.operator(), caller);
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun execute_set_operator(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetOperatorReq>();
        mtoken::execute_set_operator(&mut state, req, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_operator(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetOperatorReq>();
        mtoken::revoke_set_operator(&state, req, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_operator(scenario: &mut test_scenario::Scenario, operator: address) {
    scenario.next_tx(operator);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.operator(), operator);
        test_scenario::return_shared(state);
    };
}

fun request_set_revoker(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_revoker: address,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::request_set_revoker(&state, new_revoker, _clock, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun execute_set_revoker(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetRevokerReq>();
        mtoken::execute_set_revoker(&mut state, req, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_revoker(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetRevokerReq>();
        mtoken::revoke_set_revoker(&state, req, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_revoker(scenario: &mut test_scenario::Scenario, revoker: address) {
    scenario.next_tx(revoker);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.revoker(), revoker);
        test_scenario::return_shared(state);
    };
}

fun execute_set_delay(scenario: &mut test_scenario::Scenario, _clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetDelayReq>();
        mtoken::execute_set_delay(&mut state, req, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

fun revoke_set_delay(scenario: &mut test_scenario::Scenario, caller: address) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let req = scenario.take_shared<mtoken::SetDelayReq>();
        mtoken::revoke_set_delay(&state, req, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

fun check_delay(scenario: &mut test_scenario::Scenario, caller: address, delay: u64) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.delay(), delay);
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
        mtoken::request_mint_to(&state, recipient, amount, _clock, scenario.ctx());
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
    let mut scenario = init_xagm();

    // check State fields
    scenario.next_tx(ADMIN);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        assert_eq!(state.version(), VERSION);
        assert_eq!(state.owner(), ADMIN);
        assert_eq!(state.operator(), ADMIN);
        assert_eq!(state.revoker(), ADMIN);
        assert_eq!(state.delay(), INIT_DELAY);
        assert_eq!(state.mint_budget(), 0);
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

    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_description_err_not_owner() {
    let mut scenario = init_xagm();
    set_description(&mut scenario, ALICE, b"new description");
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_icon_url_err_not_owner() {
    let mut scenario = init_xagm();
    set_icon_url(&mut scenario, ALICE, b"new/icon/url");
    abort
}

#[test]
fun update_metadata_ok() {
    let new_description = b"new description";
    let new_icon_url = b"new/icon/url";
    let mut scenario = init_xagm();

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

    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_owner_req_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotNewOwner)]
fun set_owner_exec_err_not_new_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_owner(&mut scenario, &_clock, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_owner_exec_err_not_effective() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_owner(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EReqExpired)]
fun set_owner_exec_err_expired() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    _clock.increment_for_testing(REQ_TTL * 1000);
    execute_set_owner(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::EUpgradeCapInvalid)]
fun set_owner_req_err_upgrade_cap_invalid() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_set_owner(&mut scenario, &_clock, ALICE);

    // check upgrade cap
    scenario.next_tx(ALICE);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        let upgrade_cap = scenario.take_from_sender<UpgradeCap>();
        assert_eq!(state.owner(), ALICE);
        assert_eq!(upgrade_cap.package(), state.package_address().to_id());
        test_scenario::return_shared(state);
        scenario.return_to_sender(upgrade_cap);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_owner_revoke_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_owner(&mut scenario, ALICE);
    abort
}

#[test]
fun set_owner_revoke_ok() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_owner(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_owner(&mut scenario, ADMIN);

    // check upgrade cap
    scenario.next_tx(ADMIN);
    {
        let _upgrade_cap = scenario.take_from_sender<UpgradeCap>();
        // assert_eq!(object::id(&upgrade_cap), object::id_from_address(@123));
        scenario.return_to_sender(_upgrade_cap);
    };

    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_operator_req_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_operator_exec_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ADMIN, BOB);
    execute_set_operator(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_operator_exec_err_not_effective() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_operator(&mut scenario, &_clock, ADMIN);
    abort
}

#[test]
fun set_operator_ok() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    check_operator(&mut scenario, ADMIN);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_set_operator(&mut scenario, &_clock, ADMIN);
    check_operator(&mut scenario, ALICE);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotRevoker)]
fun set_operator_revoke_err_not_revoker() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_operator(&mut scenario, ALICE);
    abort
}

#[test]
fun set_operator_revoke_ok() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_operator(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_operator(&mut scenario, ADMIN);
    check_operator(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_revoker_req_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ALICE, BOB);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_revoker_exec_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ADMIN, BOB);
    execute_set_revoker(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_revoker_exec_err_not_effective() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    execute_set_revoker(&mut scenario, &_clock, ADMIN);
    abort
}

#[test]
fun set_revoker_ok() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    check_revoker(&mut scenario, ADMIN);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_set_revoker(&mut scenario, &_clock, ADMIN);
    check_revoker(&mut scenario, ALICE);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_revoker_revoke_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_revoker(&mut scenario, ALICE);
    abort
}

#[test]
fun set_revoker_revoke_ok() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_revoker(&mut scenario, &_clock, ADMIN, ALICE);
    revoke_set_revoker(&mut scenario, ADMIN);
    check_revoker(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

fun request_set_delay(
    scenario: &mut test_scenario::Scenario,
    _clock: &Clock,
    caller: address,
    new_delay: u64,
) {
    scenario.next_tx(caller);
    {
        let state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::request_set_delay(&state, new_delay, _clock, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        test_scenario::return_shared(state);
    };
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_delay_req_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ALICE, 1234);
    abort
}

#[test, expected_failure(abort_code = mtoken::EDelayTooShort)]
fun set_delay_req_err_too_short() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY-1);
    abort
}

#[test, expected_failure(abort_code = mtoken::EDelayTooLong)]
fun set_delay_req_err_too_long() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MAX_DELAY+1);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOwner)]
fun set_delay_exec_err_not_owner() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+123);
    execute_set_delay(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun set_delay_exec_err_not_effective() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+123);
    execute_set_delay(&mut scenario, &_clock, ADMIN);
    abort
}

#[test]
fun set_delay_ok() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+100);
    check_delay(&mut scenario, ADMIN, INIT_DELAY);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_set_delay(&mut scenario, &_clock, ADMIN);
    check_delay(&mut scenario, ADMIN, MIN_DELAY+100);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotRevoker)]
fun set_delay_revoke_err_not_revoker() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY);
    revoke_set_delay(&mut scenario, ALICE);
    abort
}

#[test]
fun set_delay_revoke_ok() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_set_delay(&mut scenario, &_clock, ADMIN, MIN_DELAY+1);
    revoke_set_delay(&mut scenario, ADMIN);
    check_delay(&mut scenario, ADMIN, INIT_DELAY);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun mint_req_err_not_operator() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ALICE, ALICE, 100);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun mint_exec_err_not_operator() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);
    execute_mint_to(&mut scenario, &_clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = mtoken::ENotEffective)]
fun mint_exec_err_not_effective() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);
    execute_mint_to(&mut scenario, &_clock, ADMIN);
    abort
}

#[test, expected_failure(abort_code = mtoken::EMintBudgetNotEnough)]
fun mint_exec_err_budget_not_enough() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);
    abort
}

#[test]
fun mint_ok() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);

    _clock.increment_for_testing(INIT_DELAY * 1000);
    set_mint_budget(&mut scenario, ADMIN, 10000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);

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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());
    set_mint_budget(&mut scenario, ADMIN, 1000);

    // mint#1
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);

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
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 80);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);

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

#[test, expected_failure(abort_code = mtoken::ENotRevoker)]
fun mint_revoke_err_not_revoker() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 80);
    revoke_mint_to(&mut scenario, ALICE);
    abort
}

#[test]
fun mint_revoke_ok() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 80);
    revoke_mint_to(&mut scenario, ADMIN);
    clock::destroy_for_testing(_clock);
    scenario.end();
}

fun redeem(scenario: &mut test_scenario::Scenario, caller: address, to_be_burnt: Coin<XAGM>) {
    scenario.next_tx(caller);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        mtoken::redeem(&mut state, to_be_burnt, scenario.ctx());
        test_scenario::return_shared(state);
    };
}

#[test, expected_failure(abort_code = mtoken::ENotOperator)]
fun redeem_err_not_operator() {
    let mut scenario = init_xagm();
    let _clock = clock::create_for_testing(scenario.ctx());
    let to_be_burnt = coin::from_balance(balance::zero<XAGM>(), scenario.ctx());
    redeem(&mut scenario, ALICE, to_be_burnt);
    abort
}

#[test]
fun redeem_ok() {
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

    // mint
    set_mint_budget(&mut scenario, ADMIN, 10000);
    request_mint_to(&mut scenario, &_clock, ADMIN, ADMIN, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);

    // burn
    scenario.next_tx(ADMIN);
    {
        let mut state = scenario.take_shared<mtoken::State<XAGM>>();
        let mut _xagm = scenario.take_from_sender<Coin<XAGM>>();
        let to_be_burnt = _xagm.split(30, scenario.ctx());
        mtoken::redeem(&mut state, to_be_burnt, scenario.ctx());
        assert_eq!(event::num_events(), 1);
        assert_eq!(
            event::events_by_type<mtoken::RedeemEvent>().pop_back(),
            mtoken::new_redeem_event(ADMIN, 30),
        );
        scenario.return_to_sender(_xagm);
        test_scenario::return_shared(state);
    };

    // check
    scenario.next_tx(ADMIN);
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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

    // block
    scenario.next_tx(ADMIN);
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
    scenario.next_tx(ADMIN);
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
    let mut scenario = init_xagm();
    let mut _clock = clock::create_for_testing(scenario.ctx());

    // mint
    set_mint_budget(&mut scenario, ADMIN, 10000);
    request_mint_to(&mut scenario, &_clock, ADMIN, ALICE, 100);
    _clock.increment_for_testing(INIT_DELAY * 1000);
    execute_mint_to(&mut scenario, &_clock, ADMIN);

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
//     let mut scenario = init_xagm();
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
