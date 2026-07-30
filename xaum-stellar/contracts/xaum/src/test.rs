#![cfg(test)]
extern crate std;

use crate::contract::Token;
use crate::TokenClient;
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    map, Address, Bytes, BytesN, Env, IntoVal, Map, String, Symbol, TryIntoVal, Val,
};

const START_TIME: u64 = 1_000_000;
const GOV_DELAY: u64 = 3600 * 24; // 24h (MIN_GOV_DELAY)
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7d
const DELAY: u64 = 3_600; // 1h (MIN_DELAY)
const MAX_DELAY: u64 = 3600 * 24 * 2; // 48h

// ---- helpers ----

fn create_token<'a>(
    e: &Env,
    owner: &Address,
    operator: &Address,
    revoker: &Address,
) -> TokenClient<'a> {
    let contract = e.register(
        Token,
        (
            owner,
            operator,
            revoker,
            7_u32,
            String::from_str(e, "XAUM Gold"),
            String::from_str(e, "XAUM"),
        ),
    );
    TokenClient::new(e, &contract)
}

fn warp(e: &Env, secs: u64) {
    e.ledger().set_timestamp(e.ledger().timestamp() + secs);
}

/// Arm gov_delay while it is still 0 (executes instantly: two calls, +1s between).
fn arm_gov_delay(e: &Env, t: &TokenClient, gov: u64) {
    t.set_gov_delay(&gov);
    warp(e, 1);
    t.set_gov_delay(&gov);
    assert_eq!(t.gov_delay(), gov);
}

/// Arm delay. Requires gov_delay already armed (>= delay). setDelay sits at the gov
/// tier, so this costs one gov_delay window.
fn arm_delay(e: &Env, t: &TokenClient, delay: u64) {
    let gov = t.gov_delay();
    t.set_delay(&delay);
    warp(e, gov + 1);
    t.set_delay(&delay);
    assert_eq!(t.delay(), delay);
}

/// Arm gov_delay then delay to the standard test values.
fn arm_delays(e: &Env, t: &TokenClient) {
    arm_gov_delay(e, t, GOV_DELAY);
    arm_delay(e, t, DELAY);
}

/// Two-phase mint that works for any current delay (registers, waits delay+1, executes).
fn do_mint(e: &Env, t: &TokenClient, to: &Address, amount: i128, nonce: u64) {
    let r = t.mint_to(to, &amount, &nonce);
    assert!(!r, "first mint_to should return false");
    warp(e, t.delay() + 1);
    let r = t.mint_to(to, &amount, &nonce);
    assert!(r, "second mint_to should return true");
}

fn ft_req_hash(
    e: &Env,
    from: &Address,
    to: &Address,
    amount: i128,
    nonce: u64,
    data: &String,
    extra: &String,
) -> BytesN<32> {
    let mut bytes = Bytes::new(e);
    bytes.append(&from.clone().to_xdr(e));
    bytes.append(&to.clone().to_xdr(e));
    bytes.append(&Bytes::from_slice(e, &amount.to_be_bytes()));
    bytes.append(&Bytes::from_slice(e, &nonce.to_be_bytes()));
    bytes.append(&data.clone().to_xdr(e));
    bytes.append(&extra.clone().to_xdr(e));
    e.crypto().sha256(&bytes).into()
}

// ---- constructor ----

#[test]
#[should_panic]
fn test_constructor_decimal_too_large() {
    let e = Env::default();
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    e.register(
        Token,
        (
            &owner,
            &operator,
            &revoker,
            19_u32,
            String::from_str(&e, "X"),
            String::from_str(&e, "X"),
        ),
    );
}

#[test]
fn test_constructor_state() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    assert_eq!(token.owner(), owner);
    assert_eq!(token.operator(), operator);
    assert_eq!(token.revoker(), revoker);
    assert_eq!(token.decimals(), 7);
    assert_eq!(token.total_supply(), 0);
    assert_eq!(token.mint_budget(), 0);
    // timelocks start disarmed
    assert_eq!(token.delay(), 0);
    assert_eq!(token.gov_delay(), 0);
    assert!(!token.paused());
    assert!(token.forced_transfer_receiver().is_none());
}

// ---- mint_to ----

#[test]
fn test_mint_to_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);

    let r = token.mint_to(&user, &500, &1);
    assert!(!r);
    assert_eq!(token.balance(&user), 0);
    assert_eq!(token.mint_budget(), 1000);

    warp(&e, 1);
    let r = token.mint_to(&user, &500, &1);
    assert!(r);
    assert_eq!(token.balance(&user), 500);
    assert_eq!(token.total_supply(), 500);
    assert_eq!(token.mint_budget(), 500);
}

#[test]
fn test_mint_to_executes_after_et() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.change_mint_budget(&1000_i128);

    let t0 = e.ledger().timestamp();
    token.mint_to(&user, &500, &1); // registers, et = t0 + DELAY
    warp(&e, DELAY + 1);
    assert!(token.mint_to(&user, &500, &1));
    assert_eq!(token.balance(&user), 500);
    let _ = t0;
}

#[test]
#[should_panic]
fn test_mint_to_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.change_mint_budget(&1000_i128);
    token.mint_to(&user, &500, &1); // registers, et = now + DELAY
    warp(&e, DELAY - 1); // still before et
    token.mint_to(&user, &500, &1); // TooEarlyToExecute
}

#[test]
fn test_mint_to_different_nonces_are_independent() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&2000_i128);
    token.mint_to(&user, &300, &1);
    token.mint_to(&user, &700, &2);
    warp(&e, 1);
    assert!(token.mint_to(&user, &700, &2));
    assert_eq!(token.balance(&user), 700);
    assert!(token.mint_to(&user, &300, &1));
    assert_eq!(token.balance(&user), 1000);
}

#[test]
fn test_revoke_mint_request_by_owner_and_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&2000_i128);

    // register nonce 1, revoke by owner
    token.mint_to(&user, &300, &1);
    let req1 = {
        let mut bytes = Bytes::new(&e);
        bytes.append(&user.clone().to_xdr(&e));
        bytes.append(&Bytes::from_slice(&e, &300_i128.to_be_bytes()));
        bytes.append(&Bytes::from_slice(&e, &1_u64.to_be_bytes()));
        let h: BytesN<32> = e.crypto().sha256(&bytes).into();
        h
    };
    assert!(token.mint_request_et(&req1).is_some());
    token.revoke_mint_request(&owner, &req1);
    assert!(token.mint_request_et(&req1).is_none());

    // register nonce 2, revoke by revoker
    token.mint_to(&user, &700, &2);
    let req2 = {
        let mut bytes = Bytes::new(&e);
        bytes.append(&user.clone().to_xdr(&e));
        bytes.append(&Bytes::from_slice(&e, &700_i128.to_be_bytes()));
        bytes.append(&Bytes::from_slice(&e, &2_u64.to_be_bytes()));
        let h: BytesN<32> = e.crypto().sha256(&bytes).into();
        h
    };
    token.revoke_mint_request(&revoker, &req2);
    assert!(token.mint_request_et(&req2).is_none());
}

#[test]
#[should_panic]
fn test_revoke_mint_request_by_stranger_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let stranger = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    token.mint_to(&user, &300, &1);
    let req = {
        let mut bytes = Bytes::new(&e);
        bytes.append(&user.clone().to_xdr(&e));
        bytes.append(&Bytes::from_slice(&e, &300_i128.to_be_bytes()));
        bytes.append(&Bytes::from_slice(&e, &1_u64.to_be_bytes()));
        let h: BytesN<32> = e.crypto().sha256(&bytes).into();
        h
    };
    token.revoke_mint_request(&stranger, &req); // Unauthorized
}

// ---- mint_budget ----

#[test]
fn test_change_mint_budget_increase_and_decrease() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    assert_eq!(token.mint_budget(), 1000);
    token.change_mint_budget(&500_i128);
    assert_eq!(token.mint_budget(), 1500);
    token.change_mint_budget(&-300_i128);
    assert_eq!(token.mint_budget(), 1200);
}

#[test]
#[should_panic]
fn test_change_mint_budget_below_zero_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&100_i128);
    token.change_mint_budget(&-200_i128);
}

#[test]
#[should_panic]
fn test_mint_exceeds_budget_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&100_i128);
    token.mint_to(&user, &200, &1);
    warp(&e, 1);
    token.mint_to(&user, &200, &1); // 200 > budget 100
}

// ---- transfer ----

#[test]
fn test_transfer_basic() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);

    token.transfer(&user1, &user2, &400);
    assert_eq!(token.balance(&user1), 600);
    assert_eq!(token.balance(&user2), 400);
}

#[test]
#[should_panic]
fn test_transfer_insufficient_balance_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);
    token.transfer(&user1, &user2, &1001);
}

// ---- approve / transfer_from ----

#[test]
fn test_approve_and_transfer_from() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let spender = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);

    let exp = e.ledger().sequence() + 100;
    token.approve(&user1, &spender, &500, &exp);
    assert_eq!(token.allowance(&user1, &spender), 500);
    token.transfer_from(&spender, &user1, &user2, &300);
    assert_eq!(token.balance(&user1), 700);
    assert_eq!(token.balance(&user2), 300);
    assert_eq!(token.allowance(&user1, &spender), 200);
}

// ---- burn ----

#[test]
fn test_burn_deducts_operator_balance_and_refunds_budget() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &operator, 1000, 1);
    assert_eq!(token.mint_budget(), 0);

    token.burn(&user, &400);
    assert_eq!(token.balance(&operator), 600);
    assert_eq!(token.total_supply(), 600);
    assert_eq!(token.mint_budget(), 400);
}

// ---- blocklist ----

#[test]
fn test_add_and_remove_blocked() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    assert!(!token.is_blocked(&user));
    token.add_to_blocked_list(&user);
    assert!(token.is_blocked(&user));
    token.remove_from_blocked_list(&user);
    assert!(!token.is_blocked(&user));
}

#[test]
#[should_panic]
fn test_blocked_sender_cannot_transfer() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);
    token.add_to_blocked_list(&user1);
    token.transfer(&user1, &user2, &100);
}

#[test]
fn test_blocked_user_can_still_receive() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);
    token.add_to_blocked_list(&user2);
    token.transfer(&user1, &user2, &400);
    assert_eq!(token.balance(&user2), 400);
}

// ---- set_gov_delay ----

#[test]
fn test_set_gov_delay_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    assert_eq!(token.gov_delay(), GOV_DELAY);
}

#[test]
#[should_panic]
fn test_set_gov_delay_too_small_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    token.set_gov_delay(&(GOV_DELAY - 1)); // < MIN_GOV_DELAY
}

#[test]
#[should_panic]
fn test_set_gov_delay_too_large_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    token.set_gov_delay(&(MAX_GOV_DELAY + 1)); // > MAX_GOV_DELAY
}

#[test]
#[should_panic]
fn test_set_gov_delay_below_delay_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // gov = 48h, delay = 48h; then try to lower gov below delay
    arm_gov_delay(&e, &token, MAX_DELAY);
    arm_delay(&e, &token, MAX_DELAY);
    token.set_gov_delay(&GOV_DELAY); // 24h < delay 48h → GovDelayBelowDelay
}

#[test]
fn test_revoke_next_gov_delay_by_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_gov_delay(&MAX_GOV_DELAY); // register (window = gov = 24h)
    assert!(token.et_next_gov_delay().is_some());
    token.revoke_next_gov_delay(&revoker);
    assert!(token.et_next_gov_delay().is_none());
    assert_eq!(token.gov_delay(), GOV_DELAY);
}

// ---- set_delay ----

#[test]
fn test_set_delay_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    arm_delay(&e, &token, DELAY);
    assert_eq!(token.delay(), DELAY);
}

#[test]
#[should_panic]
fn test_set_delay_too_small_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_delay(&(DELAY - 1)); // < MIN_DELAY
}

#[test]
#[should_panic]
fn test_set_delay_too_large_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    arm_gov_delay(&e, &token, MAX_GOV_DELAY);
    token.set_delay(&(MAX_DELAY + 1)); // > MAX_DELAY
}

#[test]
#[should_panic]
fn test_set_delay_exceeds_gov_delay_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    arm_gov_delay(&e, &token, GOV_DELAY); // gov = 24h
    token.set_delay(&(GOV_DELAY + 3600)); // > gov_delay → DelayExceedsGovDelay
}

#[test]
fn test_revoke_next_delay_by_owner_and_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_delay(&DELAY); // register
    token.revoke_next_delay(&owner);
    assert!(token.et_next_delay().is_none());

    token.set_delay(&DELAY); // register again
    token.revoke_next_delay(&revoker);
    assert!(token.et_next_delay().is_none());
}

#[test]
#[should_panic]
fn test_revoke_next_delay_by_stranger_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let stranger = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_delay(&DELAY);
    token.revoke_next_delay(&stranger); // Unauthorized
}

// ---- concurrent conflicting delay / gov_delay execution (invariant gov_delay >= delay) ----

// Two conflicting requests are staged concurrently: a set_delay that raises `delay` and a
// set_gov_delay that lowers `gov_delay`. Both pass their request-path checks against the
// *initial* state, so both can sit pending at once. The execution-path re-check must reject
// whichever second call would break gov_delay >= delay, and must leave that pending request
// intact for owner/revoker to revoke.

// Order A: set_delay executes first (compatible), then the conflicting set_gov_delay fails.
#[test]
fn test_concurrent_set_delay_first_then_gov_delay_conflict() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // Initial effective state: gov_delay = 48h, delay = 1h.
    arm_gov_delay(&e, &token, MAX_DELAY); // gov = 48h
    arm_delay(&e, &token, DELAY); // delay = 1h

    // Stage both requests against the initial state (both windows = current gov = 48h).
    token.set_delay(&MAX_DELAY); // raise delay -> 48h (<= gov 48h at request: ok)
    token.set_gov_delay(&GOV_DELAY); // lower gov -> 24h (>= delay 1h at request: ok)
    assert!(token.et_next_delay().is_some());
    assert!(token.et_next_gov_delay().is_some());

    // Mature both.
    warp(&e, MAX_DELAY + 1);

    // set_delay executes first: 48h <= currently effective gov 48h -> ok.
    token.set_delay(&MAX_DELAY);
    assert_eq!(token.delay(), MAX_DELAY);

    // Conflicting set_gov_delay now would set gov 24h < effective delay 48h -> must fail.
    let res = token.try_set_gov_delay(&GOV_DELAY);
    assert!(res.is_err(), "conflicting set_gov_delay execution must fail");

    // Effective invariant intact (gov 48h >= delay 48h) and the pending request survives.
    assert_eq!(token.gov_delay(), MAX_DELAY);
    assert_eq!(token.delay(), MAX_DELAY);
    assert!(
        token.gov_delay() >= token.delay(),
        "gov_delay >= delay invariant must hold"
    );
    assert!(
        token.et_next_gov_delay().is_some(),
        "failed request must remain pending so it can be revoked"
    );

    // Owner/revoker can clean it up.
    token.revoke_next_gov_delay(&revoker);
    assert!(token.et_next_gov_delay().is_none());
}

// Order B: set_gov_delay executes first (compatible), then the conflicting set_delay fails.
#[test]
fn test_concurrent_gov_delay_first_then_set_delay_conflict() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // Initial effective state: gov_delay = 7d, delay = 1h.
    arm_gov_delay(&e, &token, MAX_GOV_DELAY); // gov = 7d
    arm_delay(&e, &token, DELAY); // delay = 1h

    // Stage both requests against the initial state (both windows = current gov = 7d).
    token.set_gov_delay(&GOV_DELAY); // lower gov -> 24h (>= delay 1h at request: ok)
    token.set_delay(&MAX_DELAY); // raise delay -> 48h (<= gov 7d at request: ok)
    assert!(token.et_next_gov_delay().is_some());
    assert!(token.et_next_delay().is_some());

    // Mature both.
    warp(&e, MAX_GOV_DELAY + 1);

    // set_gov_delay executes first: 24h >= currently effective delay 1h -> ok.
    token.set_gov_delay(&GOV_DELAY);
    assert_eq!(token.gov_delay(), GOV_DELAY);

    // Conflicting set_delay now would set delay 48h > effective gov 24h -> must fail.
    let res = token.try_set_delay(&MAX_DELAY);
    assert!(res.is_err(), "conflicting set_delay execution must fail");

    // Effective invariant intact (gov 24h >= delay 1h) and the pending request survives.
    assert_eq!(token.delay(), DELAY);
    assert_eq!(token.gov_delay(), GOV_DELAY);
    assert!(
        token.gov_delay() >= token.delay(),
        "gov_delay >= delay invariant must hold"
    );
    assert!(
        token.et_next_delay().is_some(),
        "failed request must remain pending so it can be revoked"
    );

    // Owner/revoker can clean it up.
    token.revoke_next_delay(&owner);
    assert!(token.et_next_delay().is_none());
}

// ---- set_operator ----

#[test]
fn test_set_operator_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_op = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.set_operator(&new_op); // delay = 0 → register, et = now
    assert_eq!(token.next_operator(), Some(new_op.clone()));
    warp(&e, 1);
    token.set_operator(&new_op); // execute
    assert_eq!(token.operator(), new_op);
    assert!(token.et_next_operator().is_none());
}

#[test]
#[should_panic]
fn test_set_operator_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_op = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.set_operator(&new_op); // et = now + DELAY
    warp(&e, DELAY - 1);
    token.set_operator(&new_op); // TooEarlyToExecute
}

#[test]
fn test_revoke_next_operator_by_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_op = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.set_operator(&new_op);
    token.revoke_next_operator(&revoker);
    assert!(token.et_next_operator().is_none());
    assert_eq!(token.operator(), operator);
}

// ---- set_revoker (two-step accept) ----

#[test]
fn test_set_revoker_two_step_accept() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_set_revoker(&new_revoker); // gov = 0 → et = now
    assert_eq!(token.next_revoker(), Some(new_revoker.clone()));
    warp(&e, 1);
    token.accept_revoker();
    assert_eq!(token.revoker(), new_revoker);
    assert!(token.next_revoker().is_none());
}

#[test]
#[should_panic]
fn test_accept_revoker_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.request_set_revoker(&new_revoker); // et = now + GOV_DELAY
    warp(&e, GOV_DELAY - 1);
    token.accept_revoker(); // TooEarlyToExecute
}

#[test]
#[should_panic]
fn test_request_set_revoker_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let r1 = Address::generate(&e);
    let r2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_set_revoker(&r1);
    token.request_set_revoker(&r2); // PendingRequestExists
}

#[test]
#[should_panic]
fn test_accept_revoker_no_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    token.accept_revoker(); // NoPendingRevoker
}

#[test]
fn test_revoke_next_revoker_by_owner_and_operator() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_set_revoker(&new_revoker);
    token.revoke_next_revoker(&owner); // owner may revoke
    assert!(token.et_next_revoker().is_none());
    assert_eq!(token.revoker(), revoker);

    token.request_set_revoker(&new_revoker);
    token.revoke_next_revoker(&operator); // operator may revoke (adjacency rule)
    assert!(token.et_next_revoker().is_none());
}

#[test]
#[should_panic]
fn test_revoke_next_revoker_by_revoker_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_set_revoker(&new_revoker);
    token.revoke_next_revoker(&revoker); // self-exclusion → Unauthorized
}

// ---- two-step ownership ----

#[test]
fn test_two_step_ownership() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_owner = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_owner_transfer(&new_owner); // gov = 0 → et = now
    warp(&e, 1);
    token.accept_owner();
    assert_eq!(token.owner(), new_owner);
}

#[test]
fn test_revoke_next_owner_by_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_owner = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_owner_transfer(&new_owner);
    token.revoke_next_owner(&revoker); // revoker intercepts a rogue transfer
    assert!(token.et_next_owner().is_none());
    assert_eq!(token.owner(), owner);
}

#[test]
#[should_panic]
fn test_request_owner_transfer_with_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let n1 = Address::generate(&e);
    let n2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_owner_transfer(&n1);
    token.request_owner_transfer(&n2); // PendingRequestExists
}

// ---- upgrade (gov tier) ----

#[test]
fn test_request_upgrade_uses_gov_delay() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    let now = e.ledger().timestamp();
    let hash = BytesN::from_array(&e, &[1u8; 32]);
    token.request_upgrade(&hash);
    assert_eq!(token.et_next_upgrade(), Some(now + GOV_DELAY));
}

#[test]
#[should_panic]
fn test_request_upgrade_with_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    let hash1 = BytesN::from_array(&e, &[1u8; 32]);
    let hash2 = BytesN::from_array(&e, &[2u8; 32]);
    token.request_upgrade(&hash1);
    token.request_upgrade(&hash2); // PendingRequestExists
}

#[test]
fn test_revoke_next_upgrade_by_owner_and_revoker() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    let hash = BytesN::from_array(&e, &[7u8; 32]);
    token.request_upgrade(&hash);
    token.revoke_next_upgrade(&revoker);
    assert!(token.et_next_upgrade().is_none());

    token.request_upgrade(&hash);
    token.revoke_next_upgrade(&owner);
    assert!(token.et_next_upgrade().is_none());

    // idempotent: revoking with nothing pending succeeds silently
    token.revoke_next_upgrade(&owner);
    assert!(token.et_next_upgrade().is_none());
}

// revoke_next_upgrade must emit UpgradeRevoked in BOTH cases so monitoring can observe every
// revoke. Payload: the real pending hash for a valid revoke, or an all-zero BytesN<32>
// sentinel when nothing was pending (anomalous / no-op revoke). Event schema is unchanged:
// new_wasm_hash stays BytesN<32>. Assert both emission and the exact payload monitors consume.
#[test]
fn test_revoke_next_upgrade_always_emits_event() {
    use soroban_sdk::testutils::Events;
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // pending-present: revoke emits exactly one event and clears the pending upgrade.
    let hash = BytesN::from_array(&e, &[9u8; 32]);
    token.request_upgrade(&hash);
    assert!(token.et_next_upgrade().is_some());
    let before = e.events().all().len();
    token.revoke_next_upgrade(&revoker);
    assert_eq!(
        e.events().all().len(),
        before + 1,
        "revoke with pending upgrade must emit UpgradeRevoked (real hash payload)"
    );
    let (_, _, data) = e.events().all().last().unwrap();
    // Val has no PartialEq; compare the event payload as the Map it actually is.
    let data: Map<Symbol, Val> = data.try_into_val(&e).unwrap();
    let expected_data: Map<Symbol, Val> = map![
        &e,
        (Symbol::new(&e, "caller"), revoker.clone().into_val(&e)),
        (Symbol::new(&e, "new_wasm_hash"), hash.clone().into_val(&e)),
    ];
    assert_eq!(data, expected_data);
    assert!(token.et_next_upgrade().is_none());

    // pending-absent: revoke STILL emits exactly one event (the behavior change under test),
    // carrying the all-zero sentinel hash.
    let before = e.events().all().len();
    token.revoke_next_upgrade(&owner);
    assert_eq!(
        e.events().all().len(),
        before + 1,
        "revoke with no pending upgrade must still emit UpgradeRevoked (zero sentinel)"
    );
    let (_, _, data) = e.events().all().last().unwrap();
    let data: Map<Symbol, Val> = data.try_into_val(&e).unwrap();
    let expected_data: Map<Symbol, Val> = map![
        &e,
        (Symbol::new(&e, "caller"), owner.clone().into_val(&e)),
        (
            Symbol::new(&e, "new_wasm_hash"),
            BytesN::from_array(&e, &[0u8; 32]).into_val(&e)
        ),
    ];
    assert_eq!(data, expected_data);
    assert!(token.et_next_upgrade().is_none());
}

// ---- pause / unpause ----

#[test]
#[should_panic]
fn test_pause_blocks_transfer() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);
    token.pause();
    assert!(token.paused());
    token.transfer(&user1, &user2, &100); // ContractPaused
}

#[test]
#[should_panic]
fn test_pause_blocks_mint() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    token.pause();
    token.mint_to(&user, &100, &1); // ContractPaused
}

#[test]
fn test_forced_transfer_works_while_paused() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // wire receiver (gov = 0 → instant)
    token.set_forced_transfer_receiver(&receiver);
    warp(&e, 1);
    token.set_forced_transfer_receiver(&receiver);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user, 1000, 1);
    token.add_to_blocked_list(&user);
    token.pause();

    let data = String::from_str(&e, "case-1");
    let extra = String::from_str(&e, "ctx");
    // forced transfer still works while paused
    assert!(!token.forced_transfer(&user, &receiver, &400, &1, &data, &extra));
    warp(&e, 1);
    assert!(token.forced_transfer(&user, &receiver, &400, &1, &data, &extra));
    assert_eq!(token.balance(&receiver), 400);
    assert_eq!(token.balance(&user), 600);
}

#[test]
fn test_unpause_two_phase_restores_transfer() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user1 = Address::generate(&e);
    let user2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &user1, 1000, 1);
    token.pause();

    token.request_unpause(); // delay = 0 → et = now
    warp(&e, 1);
    token.unpause();
    assert!(!token.paused());

    token.transfer(&user1, &user2, &100);
    assert_eq!(token.balance(&user2), 100);
}

#[test]
#[should_panic]
fn test_unpause_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.pause();
    token.request_unpause(); // et = now + DELAY
    warp(&e, DELAY - 1);
    token.unpause(); // TooEarlyToExecute
}

#[test]
fn test_revoke_next_unpause() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.pause();
    token.request_unpause();
    assert!(token.et_next_unpause().is_some());
    token.revoke_next_unpause(&revoker);
    assert!(token.et_next_unpause().is_none());
    assert!(token.paused()); // still paused
}

#[test]
#[should_panic]
fn test_request_unpause_requires_paused() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // not paused → cannot pre-stage an unpause request (H-01 defense in depth)
    token.request_unpause(); // NotPaused
}

#[test]
fn test_pause_clears_pending_unpause() {
    // H-01 regression: a matured unpause must never survive across a pause, otherwise a
    // compromised owner could re-open the gate instantly the moment operator pauses.
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.pause();
    token.request_unpause(); // et = now + DELAY
    warp(&e, DELAY + 1); // let it mature
    assert!(token.et_next_unpause().is_some());

    // operator pauses again (e.g. a fresh incident) → pending unpause is voided
    token.pause();
    assert!(token.et_next_unpause().is_none());
    assert!(token.paused());
}

#[test]
#[should_panic]
fn test_unpause_after_pause_clears_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_delays(&e, &token);
    token.pause();
    token.request_unpause();
    warp(&e, DELAY + 1); // matured
    token.pause(); // voids the pending unpause
    token.unpause(); // NoPendingUnpause → must re-request and wait a fresh window
}

// ---- forced transfer receiver ----

#[test]
fn test_set_forced_transfer_receiver_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_forced_transfer_receiver(&receiver); // et = now + GOV_DELAY
    assert!(token.forced_transfer_receiver().is_none());
    warp(&e, GOV_DELAY + 1);
    token.set_forced_transfer_receiver(&receiver);
    assert_eq!(token.forced_transfer_receiver(), Some(receiver));
}

#[test]
fn test_revoke_forced_transfer_receiver() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    arm_gov_delay(&e, &token, GOV_DELAY);
    token.set_forced_transfer_receiver(&receiver); // register
    token.revoke_forced_transfer_receiver(&owner);
    assert!(token.et_next_forced_transfer_receiver().is_none());
    assert!(token.forced_transfer_receiver().is_none());
}

// ---- forced transfer ----

fn setup_forced_transfer<'a>(
    e: &Env,
    owner: &Address,
    operator: &Address,
    revoker: &Address,
    from: &Address,
    receiver: &Address,
) -> TokenClient<'a> {
    let token = create_token(e, owner, operator, revoker);
    // wire receiver (gov = 0 → instant)
    token.set_forced_transfer_receiver(receiver);
    warp(e, 1);
    token.set_forced_transfer_receiver(receiver);
    // fund `from` and block it
    token.change_mint_budget(&1000_i128);
    do_mint(e, &token, from, 1000, 1);
    token.add_to_blocked_list(from);
    token
}

#[test]
fn test_forced_transfer_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let from = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = setup_forced_transfer(&e, &owner, &operator, &revoker, &from, &receiver);

    let data = String::from_str(&e, "clawback");
    let extra = String::from_str(&e, "ticket-42");
    assert!(!token.forced_transfer(&from, &receiver, &400, &1, &data, &extra));
    assert_eq!(token.balance(&receiver), 0);
    warp(&e, 1);
    assert!(token.forced_transfer(&from, &receiver, &400, &1, &data, &extra));
    assert_eq!(token.balance(&receiver), 400);
    assert_eq!(token.balance(&from), 600);
}

#[test]
#[should_panic]
fn test_forced_transfer_requires_blocked_from() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let from = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.set_forced_transfer_receiver(&receiver);
    warp(&e, 1);
    token.set_forced_transfer_receiver(&receiver);
    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &from, 1000, 1);
    // NOT blocked
    let data = String::from_str(&e, "x");
    let extra = String::from_str(&e, "y");
    token.forced_transfer(&from, &receiver, &400, &1, &data, &extra); // NotBlocked
}

#[test]
#[should_panic]
fn test_forced_transfer_wrong_receiver_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let from = Address::generate(&e);
    let receiver = Address::generate(&e);
    let wrong = Address::generate(&e);
    let token = setup_forced_transfer(&e, &owner, &operator, &revoker, &from, &receiver);

    let data = String::from_str(&e, "x");
    let extra = String::from_str(&e, "y");
    token.forced_transfer(&from, &wrong, &400, &1, &data, &extra); // InvalidForcedTransferReceiver
}

#[test]
#[should_panic]
fn test_forced_transfer_no_receiver_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let from = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&1000_i128);
    do_mint(&e, &token, &from, 1000, 1);
    token.add_to_blocked_list(&from);
    let data = String::from_str(&e, "x");
    let extra = String::from_str(&e, "y");
    // receiver never set → NoForcedTransferReceiver
    token.forced_transfer(&from, &receiver, &400, &1, &data, &extra);
}

#[test]
fn test_forced_transfer_revoke() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let from = Address::generate(&e);
    let receiver = Address::generate(&e);
    let token = setup_forced_transfer(&e, &owner, &operator, &revoker, &from, &receiver);

    let data = String::from_str(&e, "clawback");
    let extra = String::from_str(&e, "ticket-42");
    token.forced_transfer(&from, &receiver, &400, &1, &data, &extra); // register
    let req = ft_req_hash(&e, &from, &receiver, 400, 1, &data, &extra);
    assert!(token.forced_transfer_request_et(&req).is_some());
    token.revoke_forced_transfer(&revoker, &req);
    assert!(token.forced_transfer_request_et(&req).is_none());
}
