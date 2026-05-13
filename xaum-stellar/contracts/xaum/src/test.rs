#![cfg(test)]
extern crate std;

use crate::contract::Token;
use crate::TokenClient;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    Address, Env, String,
};

const START_TIME: u64 = 1_000_000;
const DELAY: u64 = 3_600;

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

/// Execute a two-phase mint. Advances the ledger by 1 second between the two
/// calls so that the execution timestamp is strictly greater than et (matches
/// EVM strict-greater semantics, even when delay = 0).
fn do_mint(e: &Env, token: &TokenClient, to: &Address, amount: i128, nonce: u64) {
    let r = token.mint_to(to, &amount, &nonce);
    assert!(!r, "first mint_to should return false");
    e.ledger().set_timestamp(e.ledger().timestamp() + 1);
    let r = token.mint_to(to, &amount, &nonce);
    assert!(r, "second mint_to should return true");
}

/// Set delay via two-phase. Advances the ledger by 1 second between the two
/// calls so the execution is strictly after et (works when current delay = 0).
fn apply_delay(e: &Env, token: &TokenClient, delay: u64) {
    token.set_delay(&delay);
    e.ledger().set_timestamp(e.ledger().timestamp() + 1);
    token.set_delay(&delay);
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
    assert_eq!(token.name(), String::from_str(&e, "XAUM Gold"));
    assert_eq!(token.symbol(), String::from_str(&e, "XAUM"));
    assert_eq!(token.total_supply(), 0);
    assert_eq!(token.mint_budget(), 0);
    assert_eq!(token.delay(), 0);
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

    // first call: registers, returns false, no balance change
    let r = token.mint_to(&user, &500, &1);
    assert!(!r);
    assert_eq!(token.balance(&user), 0);
    assert_eq!(token.total_supply(), 0);
    assert_eq!(token.mint_budget(), 1000); // budget not consumed yet

    // advance past et (delay=0, et=START_TIME, need now > START_TIME)
    e.ledger().set_timestamp(START_TIME + 1);

    // second call: executes, returns true
    let r = token.mint_to(&user, &500, &1);
    assert!(r);
    assert_eq!(token.balance(&user), 500);
    assert_eq!(token.total_supply(), 500);
    assert_eq!(token.mint_budget(), 500); // 1000 - 500
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

    // after apply_delay the timestamp is START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.change_mint_budget(&1000_i128);

    token.mint_to(&user, &500, &1); // registers, et = (START_TIME+1) + DELAY

    // advance strictly past et
    e.ledger().set_timestamp(START_TIME + 1 + DELAY + 1);
    let r = token.mint_to(&user, &500, &1);
    assert!(r);
    assert_eq!(token.balance(&user), 500);
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

    // after apply_delay timestamp = START_TIME+1, et = START_TIME+1+DELAY
    apply_delay(&e, &token, DELAY);
    token.change_mint_budget(&1000_i128);
    token.mint_to(&user, &500, &1); // registers

    e.ledger().set_timestamp(START_TIME + DELAY - 1); // still before et
    token.mint_to(&user, &500, &1); // panics TooEarlyToExecute
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

    // delay=0: both registered at START_TIME, et=START_TIME
    token.mint_to(&user, &300, &1); // register nonce 1
    token.mint_to(&user, &700, &2); // register nonce 2

    // advance strictly past et
    e.ledger().set_timestamp(START_TIME + 1);

    // execute nonce 2 first
    assert!(token.mint_to(&user, &700, &2));
    assert_eq!(token.balance(&user), 700);

    // then execute nonce 1
    assert!(token.mint_to(&user, &300, &1));
    assert_eq!(token.balance(&user), 1000);
}

#[test]
fn test_mint_request_et_getter() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay timestamp = START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.change_mint_budget(&1000_i128);

    // before registration: returns 0
    use soroban_sdk::{xdr::ToXdr, Bytes, BytesN};
    let mut bytes = Bytes::new(&e);
    bytes.append(&user.clone().to_xdr(&e));
    bytes.append(&Bytes::from_slice(&e, &500_i128.to_be_bytes()));
    bytes.append(&Bytes::from_slice(&e, &1_u64.to_be_bytes()));
    let req: BytesN<32> = e.crypto().sha256(&bytes).into();
    assert!(token.mint_request_et(&req).is_none());

    token.mint_to(&user, &500, &1); // registers, et = (START_TIME+1) + DELAY
    assert_eq!(token.mint_request_et(&req), Some(START_TIME + 1 + DELAY));

    e.ledger().set_timestamp(START_TIME + 1 + DELAY + 1); // strictly after et
    token.mint_to(&user, &500, &1); // executes, removes entry
    assert!(token.mint_request_et(&req).is_none());
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
    token.change_mint_budget(&-200_i128); // 100 - 200 < 0 → MintBudgetNotEnough
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
    token.mint_to(&user, &200, &1); // register 200
    e.ledger().set_timestamp(START_TIME + 1);
    token.mint_to(&user, &200, &1); // execute: 200 > budget 100 → panics
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
    assert_eq!(token.total_supply(), 1000);
}

#[test]
fn test_transfer_zero() {
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

    token.transfer(&user1, &user2, &0);
    assert_eq!(token.balance(&user1), 1000);
    assert_eq!(token.balance(&user2), 0);
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
    assert_eq!(token.allowance(&user1, &spender), 200); // 500 - 300
}

#[test]
#[should_panic]
fn test_transfer_from_insufficient_allowance_panics() {
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
    token.approve(&user1, &spender, &100, &exp);
    token.transfer_from(&spender, &user1, &user2, &101);
}

#[test]
fn test_approve_zero_clears_allowance() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let spender = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    let exp = e.ledger().sequence() + 100;
    token.approve(&user, &spender, &500, &exp);
    assert_eq!(token.allowance(&user, &spender), 500);

    token.approve(&user, &spender, &0, &exp);
    assert_eq!(token.allowance(&user, &spender), 0);
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
    // mint to operator (simulates user transferring tokens to operator before redeem)
    do_mint(&e, &token, &operator, 1000, 1);
    assert_eq!(token.mint_budget(), 0); // budget consumed by mint

    // operator burns 400 from their own balance; `user` is only for the event
    token.burn(&user, &400);
    assert_eq!(token.balance(&operator), 600);
    assert_eq!(token.total_supply(), 600);
    assert_eq!(token.mint_budget(), 400); // refunded
}

#[test]
#[should_panic]
fn test_burn_insufficient_operator_balance_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let user = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.change_mint_budget(&500_i128);
    do_mint(&e, &token, &operator, 100, 1);
    token.burn(&user, &200); // operator only has 100
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
    token.transfer(&user1, &user2, &100); // UserBlocked
}

#[test]
#[should_panic]
fn test_blocked_spender_cannot_use_transfer_from() {
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
    token.add_to_blocked_list(&spender);
    token.transfer_from(&spender, &user1, &user2, &100); // UserBlocked
}

#[test]
#[should_panic]
fn test_blocked_from_address_cannot_be_drained_via_transfer_from() {
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
    token.add_to_blocked_list(&user1); // block the from
    token.transfer_from(&spender, &user1, &user2, &100); // UserBlocked
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
    token.add_to_blocked_list(&user2); // block recipient

    // user1 (not blocked) sends to blocked user2 — should succeed
    token.transfer(&user1, &user2, &400);
    assert_eq!(token.balance(&user2), 400);
}

#[test]
fn test_unblock_restores_transfer() {
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
    token.remove_from_blocked_list(&user1);
    token.transfer(&user1, &user2, &400); // should succeed
    assert_eq!(token.balance(&user2), 400);
}

// ---- set_delay timelock ----

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
    token.set_delay(&3599); // < MIN_DELAY (3600)
}

#[test]
fn test_set_delay_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.set_delay(&DELAY);
    e.ledger().set_timestamp(START_TIME + 1); // advance past et (delay was 0, et=START_TIME)
    token.set_delay(&DELAY);
    assert_eq!(token.delay(), DELAY);
}

#[test]
#[should_panic]
fn test_set_delay_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay: timestamp = START_TIME+1, delay = DELAY
    apply_delay(&e, &token, DELAY);
    let new_delay = 7200_u64;
    token.set_delay(&new_delay); // registers at START_TIME+1, et = START_TIME+1+DELAY
                                 // still at START_TIME+1, too early
    token.set_delay(&new_delay); // TooEarlyToExecute
}

#[test]
fn test_set_delay_executes_after_et() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay: timestamp = START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.set_delay(&7200_u64); // registers at START_TIME+1, et = START_TIME+1+DELAY
    e.ledger().set_timestamp(START_TIME + 1 + DELAY + 1); // strictly after et
    token.set_delay(&7200_u64); // executes
    assert_eq!(token.delay(), 7200);
}

#[test]
#[should_panic]
fn test_set_delay_pending_different_value_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    apply_delay(&e, &token, DELAY);
    token.set_delay(&7200_u64); // pending for 7200
    token.set_delay(&10800_u64); // different → PendingRequestExists
}

#[test]
fn test_revoke_next_delay_and_reregister() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay: timestamp = START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.set_delay(&7200_u64); // registers at START_TIME+1
    token.revoke_next_delay(); // revoker cancels
    assert!(token.et_next_delay().is_none());

    // re-register with a fresh timestamp; et = (START_TIME+DELAY+1) + DELAY
    e.ledger().set_timestamp(START_TIME + DELAY + 1);
    token.set_delay(&7200_u64);
    e.ledger().set_timestamp(START_TIME + DELAY + 1 + DELAY + 1); // strictly after new et
    token.set_delay(&7200_u64); // executes
    assert_eq!(token.delay(), 7200);
}

// ---- set_operator timelock ----

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

    // after apply_delay: timestamp = START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.set_operator(&new_op); // registers at START_TIME+1, et = START_TIME+1+DELAY
    assert_eq!(token.next_operator(), Some(new_op.clone()));
    assert_eq!(token.et_next_operator(), Some(START_TIME + 1 + DELAY));

    e.ledger().set_timestamp(START_TIME + 1 + DELAY + 1); // strictly after et
    token.set_operator(&new_op); // executes
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

    // after apply_delay: timestamp = START_TIME+1, et = START_TIME+1+DELAY
    apply_delay(&e, &token, DELAY);
    token.set_operator(&new_op);
    e.ledger().set_timestamp(START_TIME + DELAY - 1); // still before et
    token.set_operator(&new_op); // TooEarlyToExecute
}

#[test]
#[should_panic]
fn test_set_operator_pending_different_value_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_op1 = Address::generate(&e);
    let new_op2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    apply_delay(&e, &token, DELAY);
    token.set_operator(&new_op1);
    token.set_operator(&new_op2); // PendingRequestExists
}

#[test]
fn test_revoke_next_operator() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_op = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    apply_delay(&e, &token, DELAY);
    token.set_operator(&new_op);
    token.revoke_next_operator();

    assert!(token.et_next_operator().is_none());
    assert_eq!(token.operator(), operator); // original unchanged
}

// ---- set_revoker timelock ----

#[test]
fn test_set_revoker_two_phase() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay: timestamp = START_TIME+1
    apply_delay(&e, &token, DELAY);
    token.set_revoker(&new_revoker); // registers at START_TIME+1, et = START_TIME+1+DELAY
    e.ledger().set_timestamp(START_TIME + 1 + DELAY + 1); // strictly after et
    token.set_revoker(&new_revoker);
    assert_eq!(token.revoker(), new_revoker);
}

#[test]
#[should_panic]
fn test_set_revoker_too_early_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    // after apply_delay: timestamp = START_TIME+1, et = START_TIME+1+DELAY
    apply_delay(&e, &token, DELAY);
    token.set_revoker(&new_revoker);
    e.ledger().set_timestamp(START_TIME + DELAY - 1); // still before et
    token.set_revoker(&new_revoker); // TooEarlyToExecute
}

#[test]
#[should_panic]
fn test_set_revoker_pending_different_value_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker1 = Address::generate(&e);
    let new_revoker2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    apply_delay(&e, &token, DELAY);
    token.set_revoker(&new_revoker1);
    token.set_revoker(&new_revoker2); // PendingRequestExists
}

#[test]
fn test_owner_can_revoke_pending_revoker_change() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    apply_delay(&e, &token, DELAY);
    token.set_revoker(&new_revoker);
    token.revoke_next_revoker(); // owner cancels
    assert!(token.et_next_revoker().is_none());
    assert_eq!(token.revoker(), revoker); // original unchanged
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

    // gov_delay=0: et = START_TIME; advance past it before accepting
    token.request_owner_transfer(&new_owner);
    e.ledger().set_timestamp(START_TIME + 1);
    token.accept_owner();
    assert_eq!(token.owner(), new_owner);
}

#[test]
#[should_panic]
fn test_accept_owner_after_revoke_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let new_owner = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_owner_transfer(&new_owner);
    token.revoke_next_owner(); // cancels: removes both pending_owner and et
    e.ledger().set_timestamp(START_TIME + 1);
    token.accept_owner(); // must panic: NoPendingOwner
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
    let new_owner1 = Address::generate(&e);
    let new_owner2 = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);

    token.request_owner_transfer(&new_owner1); // registers
    token.request_owner_transfer(&new_owner2); // PendingRequestExists
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

    let hash1 = soroban_sdk::BytesN::from_array(&e, &[1u8; 32]);
    let hash2 = soroban_sdk::BytesN::from_array(&e, &[2u8; 32]);
    token.request_upgrade(&hash1); // registers
    token.request_upgrade(&hash2); // PendingRequestExists
}

#[test]
#[should_panic]
fn test_accept_owner_with_no_pending_panics() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(START_TIME);
    let owner = Address::generate(&e);
    let operator = Address::generate(&e);
    let revoker = Address::generate(&e);
    let token = create_token(&e, &owner, &operator, &revoker);
    token.accept_owner(); // NoPendingOwner
}
