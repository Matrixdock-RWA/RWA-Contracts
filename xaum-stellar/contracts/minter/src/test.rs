#![cfg(test)]
extern crate std;

use crate::contract::BullionMinter;
use crate::BullionMinterClient;
use soroban_sdk::{
    contract, contractimpl,
    testutils::{Address as _, Ledger},
    token::TokenInterface,
    map, Address, Bytes, BytesN, Env, IntoVal, Map, MuxedAddress, String, Symbol, TryIntoVal, Val,
    Vec,
};

const START_TIME: u64 = 1_000_000;
const GOV_DELAY: u64 = 3600 * 24; // 24h (MIN_GOV_DELAY)
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7d

fn warp(e: &Env, secs: u64) {
    e.ledger().set_timestamp(e.ledger().timestamp() + secs);
}

/// Arm gov_delay while it is still 0 (executes instantly: two calls, +1s between).
fn arm_gov_delay(e: &Env, m: &BullionMinterClient, gov: u64) {
    m.set_gov_delay(&gov);
    warp(e, 1);
    m.set_gov_delay(&gov);
    assert_eq!(m.gov_delay(), gov);
}

// ---- inline mock token ----

/// Minimal token that tracks balances in persistent storage.
/// Implements TokenInterface so the minter can call transfer() on it.
#[contract]
pub struct MockToken;

#[contractimpl]
impl MockToken {
    pub fn mint(env: Env, to: Address, amount: i128) {
        let bal: i128 = env.storage().persistent().get(&to).unwrap_or(0);
        env.storage().persistent().set(&to, &(bal + amount));
    }
}

#[contractimpl]
impl TokenInterface for MockToken {
    fn allowance(_env: Env, _from: Address, _spender: Address) -> i128 {
        0
    }
    fn approve(
        _env: Env,
        _from: Address,
        _spender: Address,
        _amount: i128,
        _expiration_ledger: u32,
    ) {
    }
    fn balance(env: Env, id: Address) -> i128 {
        env.storage().persistent().get(&id).unwrap_or(0)
    }
    fn transfer(env: Env, from: Address, to_muxed: MuxedAddress, amount: i128) {
        from.require_auth();
        let to = to_muxed.address();
        let from_bal: i128 = env.storage().persistent().get(&from).unwrap_or(0);
        let to_bal: i128 = env.storage().persistent().get(&to).unwrap_or(0);
        env.storage().persistent().set(&from, &(from_bal - amount));
        env.storage().persistent().set(&to, &(to_bal + amount));
    }
    fn transfer_from(_env: Env, _spender: Address, _from: Address, _to: Address, _amount: i128) {}
    fn burn(_env: Env, _from: Address, _amount: i128) {}
    fn burn_from(_env: Env, _spender: Address, _from: Address, _amount: i128) {}
    fn decimals(_env: Env) -> u32 {
        9
    }
    fn name(env: Env) -> String {
        String::from_str(&env, "Mock")
    }
    fn symbol(env: Env) -> String {
        String::from_str(&env, "MCK")
    }
}

// ---- helpers ----

struct Setup<'a> {
    owner: Address,
    pool_a: Address,
    pool_b: Address,
    token_a: Address,
    token_b: Address,
    minter: BullionMinterClient<'a>,
}

fn setup<'a>(env: &'a Env) -> Setup<'a> {
    env.mock_all_auths();
    env.ledger().set_timestamp(START_TIME);

    let owner = Address::generate(env);
    let pool_a = Address::generate(env);
    let pool_b = Address::generate(env);

    let token_a = env.register(MockToken, ());
    let token_b = env.register(MockToken, ());

    let tokens_a: Vec<Address> = soroban_sdk::vec![env, token_a.clone()];
    let tokens_b: Vec<Address> = soroban_sdk::vec![env, token_b.clone()];

    let minter_addr = env.register(
        BullionMinter,
        (&owner, &pool_a, &pool_b, &tokens_a, &tokens_b),
    );
    let minter = BullionMinterClient::new(env, &minter_addr);

    Setup {
        owner,
        pool_a,
        pool_b,
        token_a,
        token_b,
        minter,
    }
}

fn token_balance(env: &Env, token: &Address, account: &Address) -> i128 {
    soroban_sdk::token::TokenClient::new(env, token).balance(account)
}

fn mint_mock(env: &Env, token: &Address, to: &Address, amount: i128) {
    MockTokenClient::new(env, token).mint(to, &amount);
}

// ---- constructor ----

#[test]
fn test_constructor_sets_state() {
    let e = Env::default();
    let s = setup(&e);

    assert_eq!(s.minter.owner(), s.owner);
    assert_eq!(s.minter.pool_account_a(), s.pool_a);
    assert_eq!(s.minter.pool_account_b(), s.pool_b);

    assert!(s.minter.is_accepted_by_a(&s.token_a));
    assert!(s.minter.is_accepted_by_b(&s.token_b));
    assert!(!s.minter.is_accepted_by_a(&s.token_b));
    assert!(!s.minter.is_accepted_by_b(&s.token_a));
}

// ---- request_to_mint ----

#[test]
fn test_request_to_mint_transfers_to_pool_a() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);

    mint_mock(&e, &s.token_a, &user, 1000);
    assert_eq!(token_balance(&e, &s.token_a, &user), 1000);

    s.minter.request_to_mint(
        &user,
        &s.token_a,
        &s.token_b,
        &500,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );

    assert_eq!(token_balance(&e, &s.token_a, &user), 500);
    assert_eq!(token_balance(&e, &s.token_a, &s.pool_a), 500);
}

#[test]
#[should_panic]
fn test_request_to_mint_invalid_transferred_token_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    let unknown_token = Address::generate(&e);

    s.minter.request_to_mint(
        &user,
        &unknown_token, // not accepted by A
        &s.token_b,
        &100,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );
}

#[test]
#[should_panic]
fn test_request_to_mint_invalid_for_token_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    let unknown_token = Address::generate(&e);

    s.minter.request_to_mint(
        &user,
        &s.token_a,
        &unknown_token, // not accepted by B
        &100,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );
}

#[test]
#[should_panic]
fn test_request_to_mint_stale_timestamp_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);

    // timestamp is 60 seconds before now (> DELAY_MAX = 59)
    s.minter.request_to_mint(
        &user,
        &s.token_a,
        &s.token_b,
        &100,
        &1000_u128,
        &10_u128,
        &(START_TIME - 60),
        &Bytes::new(&e),
    );
}

#[test]
fn test_request_to_mint_accepts_timestamp_at_boundary() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    mint_mock(&e, &s.token_a, &user, 1000);

    // timestamp exactly 59 seconds ago = boundary (now - 59 <= timestamp <= now)
    s.minter.request_to_mint(
        &user,
        &s.token_a,
        &s.token_b,
        &100,
        &1000_u128,
        &10_u128,
        &(START_TIME - 59),
        &Bytes::new(&e),
    );
    assert_eq!(token_balance(&e, &s.token_a, &user), 900);
}

// ---- request_to_redeem ----

#[test]
fn test_request_to_redeem_transfers_to_pool_b() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);

    mint_mock(&e, &s.token_b, &user, 1000);

    s.minter.request_to_redeem(
        &user,
        &s.token_b,
        &s.token_a,
        &300,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );

    assert_eq!(token_balance(&e, &s.token_b, &user), 700);
    assert_eq!(token_balance(&e, &s.token_b, &s.pool_b), 300);
}

#[test]
#[should_panic]
fn test_request_to_redeem_invalid_transferred_token_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    let unknown_token = Address::generate(&e);

    s.minter.request_to_redeem(
        &user,
        &unknown_token, // not accepted by B
        &s.token_a,
        &100,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );
}

#[test]
#[should_panic]
fn test_request_to_redeem_invalid_for_token_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    let unknown_token = Address::generate(&e);

    s.minter.request_to_redeem(
        &user,
        &s.token_b,
        &unknown_token, // not accepted by A
        &100,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );
}

#[test]
#[should_panic]
fn test_request_to_redeem_stale_timestamp_panics() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);

    s.minter.request_to_redeem(
        &user,
        &s.token_b,
        &s.token_a,
        &100,
        &1000_u128,
        &10_u128,
        &(START_TIME - 60),
        &Bytes::new(&e),
    );
}

// ---- admin: set_accepted_by ----

#[test]
fn test_set_accepted_by_a_add_and_remove() {
    let e = Env::default();
    let s = setup(&e);
    let new_token = Address::generate(&e);

    assert!(!s.minter.is_accepted_by_a(&new_token));
    s.minter.set_accepted_by_a(&new_token, &true);
    assert!(s.minter.is_accepted_by_a(&new_token));
    s.minter.set_accepted_by_a(&new_token, &false);
    assert!(!s.minter.is_accepted_by_a(&new_token));
}

#[test]
fn test_set_accepted_by_b_add_and_remove() {
    let e = Env::default();
    let s = setup(&e);
    let new_token = Address::generate(&e);

    assert!(!s.minter.is_accepted_by_b(&new_token));
    s.minter.set_accepted_by_b(&new_token, &true);
    assert!(s.minter.is_accepted_by_b(&new_token));
    s.minter.set_accepted_by_b(&new_token, &false);
    assert!(!s.minter.is_accepted_by_b(&new_token));
}

// ---- admin: set_pool_account ----

#[test]
fn test_set_pool_account_a() {
    let e = Env::default();
    let s = setup(&e);
    let new_pool = Address::generate(&e);

    s.minter.set_pool_account_a(&new_pool);
    assert_eq!(s.minter.pool_account_a(), new_pool);
}

#[test]
fn test_set_pool_account_b() {
    let e = Env::default();
    let s = setup(&e);
    let new_pool = Address::generate(&e);

    s.minter.set_pool_account_b(&new_pool);
    assert_eq!(s.minter.pool_account_b(), new_pool);
}

// ---- two-step ownership ----

#[test]
fn test_two_step_ownership() {
    let e = Env::default();
    let s = setup(&e);
    let new_owner = Address::generate(&e);

    // gov_delay = 0 (disarmed): et = now; advance past it before accepting
    s.minter.request_owner_transfer(&new_owner);
    warp(&e, 1);
    s.minter.accept_owner();
    assert_eq!(s.minter.owner(), new_owner);
}

#[test]
fn test_owner_transfer_uses_gov_delay() {
    let e = Env::default();
    let s = setup(&e);
    let new_owner = Address::generate(&e);

    arm_gov_delay(&e, &s.minter, GOV_DELAY);
    let now = e.ledger().timestamp();
    s.minter.request_owner_transfer(&new_owner);
    assert_eq!(s.minter.et_next_owner(), Some(now + GOV_DELAY));
    warp(&e, GOV_DELAY + 1);
    s.minter.accept_owner();
    assert_eq!(s.minter.owner(), new_owner);
}

#[test]
#[should_panic]
fn test_accept_owner_no_pending_panics() {
    let e = Env::default();
    let s = setup(&e);
    s.minter.accept_owner(); // NoPendingOwner
}

// ---- gov delay ----

#[test]
fn test_set_gov_delay_two_phase() {
    let e = Env::default();
    let s = setup(&e);
    assert_eq!(s.minter.gov_delay(), 0);
    arm_gov_delay(&e, &s.minter, GOV_DELAY);
    assert_eq!(s.minter.gov_delay(), GOV_DELAY);
}

#[test]
#[should_panic]
fn test_set_gov_delay_too_small_panics() {
    let e = Env::default();
    let s = setup(&e);
    s.minter.set_gov_delay(&(GOV_DELAY - 1)); // < MIN_GOV_DELAY
}

#[test]
#[should_panic]
fn test_set_gov_delay_too_large_panics() {
    let e = Env::default();
    let s = setup(&e);
    s.minter.set_gov_delay(&(MAX_GOV_DELAY + 1)); // > MAX_GOV_DELAY
}

#[test]
fn test_revoke_next_gov_delay() {
    let e = Env::default();
    let s = setup(&e);

    arm_gov_delay(&e, &s.minter, GOV_DELAY);
    s.minter.set_gov_delay(&MAX_GOV_DELAY); // register (window = gov = 24h)
    assert!(s.minter.et_next_gov_delay().is_some());
    s.minter.revoke_next_gov_delay();
    assert!(s.minter.et_next_gov_delay().is_none());
    assert_eq!(s.minter.gov_delay(), GOV_DELAY);
}

#[test]
fn test_upgrade_request_uses_gov_delay() {
    let e = Env::default();
    let s = setup(&e);

    arm_gov_delay(&e, &s.minter, GOV_DELAY);
    let now = e.ledger().timestamp();
    let hash = soroban_sdk::BytesN::from_array(&e, &[3u8; 32]);
    s.minter.request_upgrade(&hash);
    assert_eq!(s.minter.et_next_upgrade(), Some(now + GOV_DELAY));
}

// revoke_next_upgrade must emit UpgradeRevoked in BOTH cases so monitoring can observe every
// revoke. Payload: the real pending hash for a valid revoke, or an all-zero BytesN<32>
// sentinel when nothing was pending (anomalous / no-op revoke). Event schema is unchanged:
// new_wasm_hash stays BytesN<32>. Assert both emission and the exact payload monitors consume.
#[test]
fn test_revoke_next_upgrade_always_emits_event() {
    use soroban_sdk::testutils::Events;
    let e = Env::default();
    let s = setup(&e);

    // pending-present: revoke emits exactly one event and clears the pending upgrade.
    let hash = soroban_sdk::BytesN::from_array(&e, &[9u8; 32]);
    s.minter.request_upgrade(&hash);
    assert!(s.minter.et_next_upgrade().is_some());
    let before = e.events().all().len();
    s.minter.revoke_next_upgrade();
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
        (Symbol::new(&e, "owner"), s.owner.clone().into_val(&e)),
        (Symbol::new(&e, "new_wasm_hash"), hash.clone().into_val(&e)),
    ];
    assert_eq!(data, expected_data);
    assert!(s.minter.et_next_upgrade().is_none());

    // pending-absent: revoke STILL emits exactly one event (the behavior change under test),
    // carrying the all-zero sentinel hash.
    let before = e.events().all().len();
    s.minter.revoke_next_upgrade();
    assert_eq!(
        e.events().all().len(),
        before + 1,
        "revoke with no pending upgrade must still emit UpgradeRevoked (zero sentinel)"
    );
    let (_, _, data) = e.events().all().last().unwrap();
    let data: Map<Symbol, Val> = data.try_into_val(&e).unwrap();
    let expected_data: Map<Symbol, Val> = map![
        &e,
        (Symbol::new(&e, "owner"), s.owner.clone().into_val(&e)),
        (
            Symbol::new(&e, "new_wasm_hash"),
            BytesN::from_array(&e, &[0u8; 32]).into_val(&e)
        ),
    ];
    assert_eq!(data, expected_data);
    assert!(s.minter.et_next_upgrade().is_none());
}

// ---- removed accepted token blocks new requests ----

#[test]
#[should_panic]
fn test_removed_token_cannot_be_used_for_mint() {
    let e = Env::default();
    let s = setup(&e);
    let user = Address::generate(&e);
    mint_mock(&e, &s.token_a, &user, 1000);

    s.minter.set_accepted_by_a(&s.token_a, &false); // remove token_a from A

    s.minter.request_to_mint(
        &user,
        &s.token_a, // now invalid
        &s.token_b,
        &100,
        &1000_u128,
        &10_u128,
        &START_TIME,
        &Bytes::new(&e),
    );
}
