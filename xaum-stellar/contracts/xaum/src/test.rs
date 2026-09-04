#![cfg(test)]
extern crate std;

use crate::contract::{Token, SHARED_DECIMALS};
use crate::error::TokenError;
use crate::TokenClient;
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    testutils::{Address as _, Ledger, MockAuth, MockAuthInvoke},
    map, Address, Bytes, BytesN, Env, IntoVal, Map, String, Symbol, TryIntoVal, Val,
};

const START_TIME: u64 = 1_000_000;
const GOV_DELAY: u64 = 3600 * 24; // 24h (MIN_GOV_DELAY)
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7d
const DELAY: u64 = 3_600; // 1h (MIN_DELAY)
const MAX_DELAY: u64 = 3600 * 24 * 2; // 48h
// This chain's own eid and some other chain's, both arbitrary here: the real value is
// configured per deployment via set_local_eid.
const LOCAL_EID: u32 = 30_316;
const OTHER_EID: u32 = 30_184;

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
            SHARED_DECIMALS,
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

/// Wire the mintBudget relay: declare this chain's eid and install `submitter`.
/// set_mint_budget_submitter sits at the gov tier and uses the two-call pattern, so it
/// costs one gov_delay window (+1s, since the second call must land strictly after et).
fn arm_mint_budget_submitter(e: &Env, t: &TokenClient, submitter: &Address) {
    t.set_local_eid(&LOCAL_EID);
    t.set_mint_budget_submitter(submitter);
    warp(e, t.gov_delay() + 1);
    t.set_mint_budget_submitter(submitter);
    assert_eq!(t.mint_budget_submitter(), Some(submitter.clone()));
}

/// An Ethereum tx hash. The contract records it verbatim and never verifies it; the
/// BytesN<32> type makes any other length unrepresentable at the ABI.
fn src_tx_hash(e: &Env) -> BytesN<32> {
    BytesN::from_array(e, &[0xab_u8; 32])
}

/// Claim mintBudget from Ethereum. `new_total` is the *cumulative* total, not a delta.
fn claim_budget(e: &Env, t: &TokenClient, new_total: i128) {
    t.claim_mint_budget_from_eth(&LOCAL_EID, &new_total, &src_tx_hash(e));
}

/// Give this chain `total` of mintBudget over the relay, wiring a submitter on first use.
/// Claiming from Ethereum is the only way budget is created here, so every test that
/// needs budget goes through it.
fn fund_budget(e: &Env, t: &TokenClient, total: i128) {
    if t.mint_budget_submitter().is_none() {
        let submitter = Address::generate(e);
        arm_mint_budget_submitter(e, t, &submitter);
    }
    claim_budget(e, t, total);
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
fn test_constructor_rejects_non_shared_decimals() {
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
            SHARED_DECIMALS - 1,
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
    assert_eq!(token.decimals(), SHARED_DECIMALS);
    assert_eq!(token.total_supply(), 0);
    assert_eq!(token.mint_budget(), 0);
    // timelocks start disarmed
    assert_eq!(token.delay(), 0);
    assert_eq!(token.gov_delay(), 0);
    assert!(!token.paused());
    assert!(token.forced_transfer_receiver().is_none());
    // the mintBudget relay starts unwired: no submitter, no declared chain id, no history
    assert!(token.mint_budget_submitter().is_none());
    assert_eq!(token.local_eid(), 0);
    assert_eq!(token.total_allocated_amount(), 0);
    assert_eq!(token.total_returned_amount(), 0);
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

    fund_budget(&e, &token, 1000);

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
    fund_budget(&e, &token, 1000);

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
    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 2000);
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

    fund_budget(&e, &token, 2000);

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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 100);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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
    fund_budget(e, &token, 1000);
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
    fund_budget(&e, &token, 1000);
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

    fund_budget(&e, &token, 1000);
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

// ---- global mintBudget management (claim / return, submitter, local eid) ----

/// Fresh token plus the three role addresses, with the relay already wired to `submitter`.
fn setup_relay<'a>(
    e: &Env,
    owner: &Address,
    operator: &Address,
    revoker: &Address,
    submitter: &Address,
) -> TokenClient<'a> {
    let token = create_token(e, owner, operator, revoker);
    arm_mint_budget_submitter(e, &token, submitter);
    token
}

#[test]
fn test_claim_mint_budget_credits_cumulative_delta() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);

    claim_budget(&e, &token, 10_000);
    assert_eq!(token.mint_budget(), 10_000);
    assert_eq!(token.total_allocated_amount(), 10_000);

    // the argument is the new cumulative total, not a delta: 15_000 credits 5_000 more
    claim_budget(&e, &token, 15_000);
    assert_eq!(token.mint_budget(), 15_000);
    assert_eq!(token.total_allocated_amount(), 15_000);

    // a replayed or stale submission fails outright — never a silent no-op, so off-chain
    // can always tell "already applied" from "applied again" (PRD §4.4)
    let hash = src_tx_hash(&e);
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &15_000, &hash),
        Err(Ok(TokenError::StaleMintBudgetSubmission.into()))
    );
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &14_999, &hash),
        Err(Ok(TokenError::StaleMintBudgetSubmission.into()))
    );
    assert_eq!(token.mint_budget(), 15_000);
    assert_eq!(token.total_allocated_amount(), 15_000);

    // negative cumulative totals are rejected before anything else looks at them
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &-1, &hash),
        Err(Ok(TokenError::NegativeAmountNotAllowed.into()))
    );
}

#[test]
fn test_mint_budget_watermarks_match_canonical_uint112_domain() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);
    let hash = src_tx_hash(&e);
    let too_large = 1_i128 << 112;

    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &too_large, &hash),
        Err(Ok(TokenError::MintBudgetAmountTooLarge.into()))
    );
    assert_eq!(token.total_allocated_amount(), 0);

    assert_eq!(
        token.try_return_mint_budget_to_eth(&too_large),
        Err(Ok(TokenError::MintBudgetAmountTooLarge.into()))
    );
    assert_eq!(token.total_returned_amount(), 0);
}

#[test]
fn test_claim_mint_budget_requires_a_submitter() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    let hash = src_tx_hash(&e);

    // no submitter installed yet: nothing at all can credit budget on this chain
    token.set_local_eid(&LOCAL_EID);
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &100, &hash),
        Err(Ok(TokenError::NotMintBudgetSubmitter.into()))
    );
    assert_eq!(token.mint_budget(), 0);

    arm_mint_budget_submitter(&e, &token, &submitter);
    token.claim_mint_budget_from_eth(&LOCAL_EID, &100, &hash);
    assert_eq!(token.mint_budget(), 100);
}

#[test]
fn test_claim_and_return_authorize_only_their_own_role() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);
    let hash = src_tx_hash(&e);

    // the operator signing a claim is not enough — that is exactly the pairing the
    // submitter role exists to break up
    e.mock_auths(&[MockAuth {
        address: &operator,
        invoke: &MockAuthInvoke {
            contract: &token.address,
            fn_name: "claim_mint_budget_from_eth",
            args: (LOCAL_EID, 10_000_i128, hash.clone()).into_val(&e),
            sub_invokes: &[],
        },
    }]);
    assert!(token
        .try_claim_mint_budget_from_eth(&LOCAL_EID, &10_000, &hash)
        .is_err());
    assert_eq!(token.mint_budget(), 0);

    // the same call signed by the submitter goes through
    e.mock_auths(&[MockAuth {
        address: &submitter,
        invoke: &MockAuthInvoke {
            contract: &token.address,
            fn_name: "claim_mint_budget_from_eth",
            args: (LOCAL_EID, 10_000_i128, hash.clone()).into_val(&e),
            sub_invokes: &[],
        },
    }]);
    token.claim_mint_budget_from_eth(&LOCAL_EID, &10_000, &hash);
    assert_eq!(token.mint_budget(), 10_000);

    // and the return direction answers to the operator, not the submitter
    e.mock_auths(&[MockAuth {
        address: &submitter,
        invoke: &MockAuthInvoke {
            contract: &token.address,
            fn_name: "return_mint_budget_to_eth",
            args: (4_000_i128,).into_val(&e),
            sub_invokes: &[],
        },
    }]);
    assert!(token.try_return_mint_budget_to_eth(&4_000).is_err());
    assert_eq!(token.mint_budget(), 10_000);

    e.mock_auths(&[MockAuth {
        address: &operator,
        invoke: &MockAuthInvoke {
            contract: &token.address,
            fn_name: "return_mint_budget_to_eth",
            args: (4_000_i128,).into_val(&e),
            sub_invokes: &[],
        },
    }]);
    token.return_mint_budget_to_eth(&4_000);
    assert_eq!(token.mint_budget(), 6_000);
}

#[test]
fn test_claim_mint_budget_rejects_another_chains_submission() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);
    let hash = src_tx_hash(&e);

    // prepared for a different chain but delivered here — must fail rather than be taken
    // for this chain's own cumulative value
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&OTHER_EID, &10_000, &hash),
        Err(Ok(TokenError::WrongTargetChain.into()))
    );
    assert_eq!(token.mint_budget(), 0);
    assert_eq!(token.total_allocated_amount(), 0);

    // the same submission addressed to this chain goes through
    token.claim_mint_budget_from_eth(&LOCAL_EID, &10_000, &hash);
    assert_eq!(token.mint_budget(), 10_000);
    assert_eq!(token.total_allocated_amount(), 10_000);
}

#[test]
fn test_both_directions_fail_closed_until_local_eid_is_set() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    let hash = src_tx_hash(&e);

    // install the submitter without declaring which chain this is
    token.set_mint_budget_submitter(&submitter);
    warp(&e, 1);
    token.set_mint_budget_submitter(&submitter);
    assert_eq!(token.local_eid(), 0);

    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &100, &hash),
        Err(Ok(TokenError::LocalEidNotSet.into()))
    );
    assert_eq!(
        token.try_return_mint_budget_to_eth(&100),
        Err(Ok(TokenError::LocalEidNotSet.into()))
    );

    token.set_local_eid(&LOCAL_EID);
    token.claim_mint_budget_from_eth(&LOCAL_EID, &100, &hash);
    assert_eq!(token.mint_budget(), 100);
}

#[test]
fn test_set_local_eid_bounds_and_lock() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // 0 is the "not set" sentinel, so it is never a legal value to declare
    assert_eq!(
        token.try_set_local_eid(&0),
        Err(Ok(TokenError::ZeroValue.into()))
    );

    // freely correctable while no mintBudget has moved under it
    token.set_local_eid(&OTHER_EID);
    assert_eq!(token.local_eid(), OTHER_EID);
    token.set_local_eid(&LOCAL_EID);
    assert_eq!(token.local_eid(), LOCAL_EID);

    arm_mint_budget_submitter(&e, &token, &submitter);
    claim_budget(&e, &token, 10_000);

    // locked once a watermark exists: re-labelling the chain now would strand the
    // cumulative history recorded under the old id
    assert_eq!(
        token.try_set_local_eid(&OTHER_EID),
        Err(Ok(TokenError::LocalEidLocked.into()))
    );
    assert_eq!(token.local_eid(), LOCAL_EID);

    // ...but restating the same id stays idempotent, and 0 stays rejected
    token.set_local_eid(&LOCAL_EID);
    assert_eq!(token.local_eid(), LOCAL_EID);
    assert_eq!(
        token.try_set_local_eid(&0),
        Err(Ok(TokenError::ZeroValue.into()))
    );

    // a stranger cannot declare it at all
    let stranger = Address::generate(&e);
    e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &token.address,
            fn_name: "set_local_eid",
            args: (LOCAL_EID,).into_val(&e),
            sub_invokes: &[],
        },
    }]);
    assert!(token.try_set_local_eid(&LOCAL_EID).is_err());
}

#[test]
fn test_claim_mint_budget_src_tx_hash_is_type_enforced_bytes32() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);

    // src_tx_hash is BytesN<32>, the Soroban counterpart of the EVM bytes32: an empty,
    // short, or Solana-length (64-byte) value cannot even be encoded for this entrypoint,
    // so there is no runtime length check left to exercise. An Ethereum tx hash is accepted.
    let hash: BytesN<32> = BytesN::from_array(&e, &[0xcd_u8; 32]);
    token.claim_mint_budget_from_eth(&LOCAL_EID, &100, &hash);
    assert_eq!(token.mint_budget(), 100);
}

#[test]
fn test_return_mint_budget_shrinks_budget_by_cumulative_delta() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);
    claim_budget(&e, &token, 10_000);

    // 0 is not "strictly above" the recorded 0
    assert_eq!(
        token.try_return_mint_budget_to_eth(&0),
        Err(Ok(TokenError::StaleMintBudgetSubmission.into()))
    );
    // more than this chain actually holds
    assert_eq!(
        token.try_return_mint_budget_to_eth(&10_001),
        Err(Ok(TokenError::MintBudgetNotEnough.into()))
    );
    assert_eq!(token.mint_budget(), 10_000);
    assert_eq!(token.total_returned_amount(), 0);

    token.return_mint_budget_to_eth(&4_000);
    assert_eq!(token.mint_budget(), 6_000);
    assert_eq!(token.total_returned_amount(), 4_000);

    // cumulative again: 6_500 returns 2_500 more
    token.return_mint_budget_to_eth(&6_500);
    assert_eq!(token.mint_budget(), 3_500);
    assert_eq!(token.total_returned_amount(), 6_500);

    // a replayed instruction fails instead of returning a second time
    assert_eq!(
        token.try_return_mint_budget_to_eth(&6_500),
        Err(Ok(TokenError::StaleMintBudgetSubmission.into()))
    );
    assert_eq!(token.mint_budget(), 3_500);
    assert_eq!(
        token.try_return_mint_budget_to_eth(&-1),
        Err(Ok(TokenError::NegativeAmountNotAllowed.into()))
    );
}

#[test]
fn test_pause_blocks_claim_but_never_return() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);
    claim_budget(&e, &token, 10_000);

    token.pause();
    assert!(token.paused());

    // risk-raising direction: while paused this chain's mint capacity must not grow
    let hash = src_tx_hash(&e);
    assert_eq!(
        token.try_claim_mint_budget_from_eth(&LOCAL_EID, &20_000, &hash),
        Err(Ok(TokenError::ContractPaused.into()))
    );
    assert_eq!(token.mint_budget(), 10_000);
    assert_eq!(token.total_allocated_amount(), 10_000);

    // risk-reducing direction stays open by design: its upstream is a local redemption
    // that Ethereum's pause cannot reach, so blocking it would seal the only exit
    token.return_mint_budget_to_eth(&4_000);
    assert_eq!(token.mint_budget(), 6_000);
    assert_eq!(token.total_returned_amount(), 4_000);

    // and it resumes once unpaused
    token.request_unpause();
    warp(&e, 1);
    token.unpause();
    claim_budget(&e, &token, 20_000);
    assert_eq!(token.mint_budget(), 16_000);
}

#[test]
fn test_operator_and_submitter_must_stay_distinct() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // set_mint_budget_submitter refuses the sitting operator
    assert_eq!(
        token.try_set_mint_budget_submitter(&operator),
        Err(Ok(TokenError::OperatorSubmitterConflict.into()))
    );
    assert!(token.mint_budget_submitter().is_none());
    assert!(token.next_mint_budget_submitter().is_none());

    // gov_delay is 0 on a fresh deploy: first call queues, the next one executes
    token.set_mint_budget_submitter(&submitter);
    warp(&e, 1);
    token.set_mint_budget_submitter(&submitter);
    assert_eq!(token.mint_budget_submitter(), Some(submitter.clone()));

    // and set_operator refuses the sitting submitter
    assert_eq!(
        token.try_set_operator(&submitter),
        Err(Ok(TokenError::OperatorSubmitterConflict.into()))
    );

    // neither role was disturbed by the rejections
    assert_eq!(token.operator(), operator);
    assert_eq!(token.mint_budget_submitter(), Some(submitter));
    assert!(token.next_operator().is_none());
}

#[test]
fn test_operator_submitter_conflict_appearing_inside_the_delay_window() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let bob = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    arm_delays(&e, &token);

    // both requests are legal when queued: bob is neither the operator nor the submitter yet
    token.set_mint_budget_submitter(&bob); // gov tier
    token.set_operator(&bob); // delay tier
    warp(&e, GOV_DELAY + 1);

    // operator wins the race
    token.set_operator(&bob);
    assert_eq!(token.operator(), bob);

    // the matured submitter request must not slip through now that bob is the operator
    assert_eq!(
        token.try_set_mint_budget_submitter(&bob),
        Err(Ok(TokenError::OperatorSubmitterConflict.into()))
    );
    assert!(token.mint_budget_submitter().is_none());
}

#[test]
fn test_set_mint_budget_submitter_two_phase_and_revoke() {
    use soroban_sdk::testutils::Events;

    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let other = Address::generate(&e);
    let stranger = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    arm_gov_delay(&e, &token, GOV_DELAY);

    // request: staged, not effective
    token.set_mint_budget_submitter(&submitter);
    let (_, topics, _) = e.events().all().last().unwrap();
    let event_name: Symbol = topics.get(0).unwrap().try_into_val(&e).unwrap();
    assert_eq!(event_name, Symbol::new(&e, "mint_budget_submitter_request"));
    assert_eq!(token.next_mint_budget_submitter(), Some(submitter.clone()));
    assert!(token.et_next_mint_budget_submitter().is_some());
    assert!(token.mint_budget_submitter().is_none());

    assert_eq!(
        token.try_set_mint_budget_submitter(&submitter),
        Err(Ok(TokenError::TooEarlyToExecute.into()))
    );
    assert_eq!(
        token.try_set_mint_budget_submitter(&other),
        Err(Ok(TokenError::PendingRequestExists.into()))
    );

    // the revoker can pull a staged rotation, exactly like the other delayed ops
    token.revoke_mint_budget_submitter(&revoker);
    assert!(token.next_mint_budget_submitter().is_none());
    assert!(token.et_next_mint_budget_submitter().is_none());
    assert!(token.mint_budget_submitter().is_none());

    // ...but a stranger cannot
    assert_eq!(
        token.try_revoke_mint_budget_submitter(&stranger),
        Err(Ok(TokenError::Unauthorized.into()))
    );

    // re-request and let it mature
    token.set_mint_budget_submitter(&submitter);
    warp(&e, GOV_DELAY + 1);
    token.set_mint_budget_submitter(&submitter);
    let (_, topics, _) = e.events().all().last().unwrap();
    let event_name: Symbol = topics.get(0).unwrap().try_into_val(&e).unwrap();
    assert_eq!(event_name, Symbol::new(&e, "mint_budget_submitter_effected"));
    assert_eq!(token.mint_budget_submitter(), Some(submitter));
    assert!(token.next_mint_budget_submitter().is_none());
    assert!(token.et_next_mint_budget_submitter().is_none());
}

#[test]
fn test_claim_and_return_events_carry_everything_needed_to_reconcile() {
    use soroban_sdk::testutils::Events;
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);

    let hash = src_tx_hash(&e);
    token.claim_mint_budget_from_eth(&LOCAL_EID, &10_000, &hash);

    let (_, topics, data) = e.events().all().last().unwrap();
    // topics = [event name, caller, chain id] — the chain id is a topic so a third party
    // can filter the stream per chain, as the PRD requires
    assert_eq!(topics.len(), 3);
    let name: Symbol = topics.get(0).unwrap().try_into_val(&e).unwrap();
    assert_eq!(name, Symbol::new(&e, "claim_mint_budget_from_eth"));
    let caller: Address = topics.get(1).unwrap().try_into_val(&e).unwrap();
    assert_eq!(caller, submitter);
    let eid: u32 = topics.get(2).unwrap().try_into_val(&e).unwrap();
    assert_eq!(eid, LOCAL_EID);

    let data: Map<Symbol, Val> = data.try_into_val(&e).unwrap();
    let expected: Map<Symbol, Val> = map![
        &e,
        (Symbol::new(&e, "delta_amount"), 10_000_i128.into_val(&e)),
        (
            Symbol::new(&e, "total_allocated_amount"),
            10_000_i128.into_val(&e)
        ),
        (Symbol::new(&e, "src_tx_hash"), hash.into_val(&e)),
    ];
    assert_eq!(data, expected);

    // the return side is filterable the same way, minus the source tx hash the PRD only
    // asks of the claim/reclaim directions
    token.return_mint_budget_to_eth(&4_000);
    let (_, topics, data) = e.events().all().last().unwrap();
    assert_eq!(topics.len(), 3);
    let name: Symbol = topics.get(0).unwrap().try_into_val(&e).unwrap();
    assert_eq!(name, Symbol::new(&e, "return_mint_budget_to_eth"));
    let caller: Address = topics.get(1).unwrap().try_into_val(&e).unwrap();
    assert_eq!(caller, operator);
    let eid: u32 = topics.get(2).unwrap().try_into_val(&e).unwrap();
    assert_eq!(eid, LOCAL_EID);

    let data: Map<Symbol, Val> = data.try_into_val(&e).unwrap();
    let expected: Map<Symbol, Val> = map![
        &e,
        (Symbol::new(&e, "delta_amount"), 4_000_i128.into_val(&e)),
        (
            Symbol::new(&e, "total_returned_amount"),
            4_000_i128.into_val(&e)
        ),
    ];
    assert_eq!(data, expected);
}

#[test]
fn test_relay_round_trip_with_mint_and_redeem() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let submitter = Address::generate(&e);
    let user = Address::generate(&e);
    let token = setup_relay(&e, &owner, &operator, &revoker, &submitter);

    // Ethereum has allocated 10_000 to this chain so far
    claim_budget(&e, &token, 10_000);
    do_mint(&e, &token, &operator, 6_000, 1);
    assert_eq!(token.mint_budget(), 4_000);
    assert_eq!(token.total_supply(), 6_000);

    // a redemption burns supply and refunds the budget locally, untouched by this change
    token.burn(&user, &6_000);
    assert_eq!(token.total_supply(), 0);
    assert_eq!(token.mint_budget(), 10_000);

    // the refunded budget then goes back to Ethereum, and the cumulative pair nets out
    token.return_mint_budget_to_eth(&10_000);
    assert_eq!(token.mint_budget(), 0);
    assert_eq!(token.total_allocated_amount(), 10_000);
    assert_eq!(token.total_returned_amount(), 10_000);

    // a later allocation keeps counting up from where the cumulative total left off
    claim_budget(&e, &token, 12_500);
    assert_eq!(token.mint_budget(), 2_500);
    assert_eq!(token.total_allocated_amount(), 12_500);
}
