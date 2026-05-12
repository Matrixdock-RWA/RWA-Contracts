use soroban_sdk::{Address, BytesN, Env};

use crate::storage_types::DataKey;
use crate::storage_types::{
    ALLOW_BLOCK_EXTEND_AMOUNT, ALLOW_BLOCK_TTL_THRESHOLD, PENDING_TTL_LEDGERS,
};

pub fn read_mint_request(env: &Env, key: &BytesN<32>) -> Option<u64> {
    env.storage()
        .persistent()
        .get(&DataKey::MintRequest(key.clone()))
}

pub fn write_mint_request(env: &Env, key: &BytesN<32>, et: u64) {
    env.storage()
        .persistent()
        .set(&DataKey::MintRequest(key.clone()), &et);
}

pub fn remove_mint_request(env: &Env, key: &BytesN<32>) {
    env.storage()
        .persistent()
        .remove(&DataKey::MintRequest(key.clone()));
}

pub fn read_owner(env: &Env) -> Address {
    let key = DataKey::Owner;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_owner(env: &Env, new_owner: &Address) {
    let key = DataKey::Owner;
    env.storage().instance().set(&key, new_owner);
}

pub fn write_pending_owner(env: &Env, addr: &Address) {
    let key = DataKey::PendingOwner;
    env.storage().temporary().set(&key, addr);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn read_pending_owner(env: &Env) -> Option<Address> {
    env.storage().temporary().get(&DataKey::PendingOwner)
}

pub fn remove_pending_owner(env: &Env) {
    env.storage().temporary().remove(&DataKey::PendingOwner);
}

pub fn read_et_next_owner(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextOwner)
        .unwrap_or(0)
}

pub fn write_et_next_owner(env: &Env, et: u64) {
    let key = DataKey::EtNextOwner;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_owner(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextOwner);
}

//-------- operator ----------

pub fn read_operator(env: &Env) -> Address {
    let key = DataKey::Operator;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_operator(env: &Env, new_operator: &Address) {
    let key = DataKey::Operator;
    env.storage().instance().set(&key, new_operator);
}

pub fn read_next_operator(env: &Env) -> Option<Address> {
    env.storage().temporary().get(&DataKey::NextOperator)
}

pub fn write_next_operator(env: &Env, next: &Address) {
    let key = DataKey::NextOperator;
    env.storage().temporary().set(&key, next);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_next_operator(env: &Env) {
    env.storage().temporary().remove(&DataKey::NextOperator);
}

pub fn read_et_next_operator(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextOperator)
        .unwrap_or(0)
}

pub fn write_et_next_operator(env: &Env, et: u64) {
    let key = DataKey::EtNextOperator;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_operator(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextOperator);
}

//-------- revoker ----------

pub fn read_revoker(env: &Env) -> Address {
    let key = DataKey::Revoker;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_revoker(env: &Env, new_revoker: &Address) {
    let key = DataKey::Revoker;
    env.storage().instance().set(&key, new_revoker);
}

pub fn read_next_revoker(env: &Env) -> Option<Address> {
    env.storage().temporary().get(&DataKey::NextRevoker)
}

pub fn write_next_revoker(env: &Env, next: &Address) {
    let key = DataKey::NextRevoker;
    env.storage().temporary().set(&key, next);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_next_revoker(env: &Env) {
    env.storage().temporary().remove(&DataKey::NextRevoker);
}

pub fn read_et_next_revoker(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextRevoker)
        .unwrap_or(0)
}

pub fn write_et_next_revoker(env: &Env, et: u64) {
    let key = DataKey::EtNextRevoker;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_revoker(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextRevoker);
}

//-------- delay ----------

pub fn read_delay(env: &Env) -> u64 {
    env.storage().instance().get(&DataKey::Delay).unwrap_or(0)
}

pub fn write_delay(env: &Env, new_delay: u64) {
    env.storage().instance().set(&DataKey::Delay, &new_delay);
}

pub fn read_next_delay(env: &Env) -> Option<u64> {
    env.storage().temporary().get(&DataKey::NextDelay)
}

pub fn write_next_delay(env: &Env, next: u64) {
    let key = DataKey::NextDelay;
    env.storage().temporary().set(&key, &next);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_next_delay(env: &Env) {
    env.storage().temporary().remove(&DataKey::NextDelay);
}

pub fn read_et_next_delay(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextDelay)
        .unwrap_or(0)
}

pub fn write_et_next_delay(env: &Env, et: u64) {
    let key = DataKey::EtNextDelay;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_delay(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextDelay);
}

//-------- mintBudget ----------

pub fn read_mint_budget(env: &Env) -> i128 {
    env.storage()
        .instance()
        .get(&DataKey::MintBudget)
        .unwrap_or(0)
}

pub fn write_mint_budget(env: &Env, new_budget: i128) {
    env.storage()
        .instance()
        .set(&DataKey::MintBudget, &new_budget);
}

//-------- blocked ----------

pub fn is_blocked(env: &Env, user: &Address) -> bool {
    let key = DataKey::Blocked(user.clone());
    if env.storage().persistent().has(&key) {
        env.storage().persistent().extend_ttl(
            &key,
            ALLOW_BLOCK_TTL_THRESHOLD,
            ALLOW_BLOCK_EXTEND_AMOUNT,
        );
        true
    } else {
        false
    }
}

pub fn write_blocked(env: &Env, user: &Address, blocked: bool) {
    if blocked {
        env.storage()
            .persistent()
            .set(&DataKey::Blocked(user.clone()), &true);
    } else {
        env.storage()
            .persistent()
            .remove(&DataKey::Blocked(user.clone()));
    }
}

//-------- total supply ----------

pub fn read_total_supply(env: &Env) -> i128 {
    env.storage()
        .instance()
        .get(&DataKey::TotalSupply)
        .unwrap_or(0)
}

pub fn write_total_supply(env: &Env, new_total: i128) {
    env.storage()
        .instance()
        .set(&DataKey::TotalSupply, &new_total);
}

//-------- gov delay ----------

pub fn read_gov_delay(env: &Env) -> u64 {
    env.storage()
        .instance()
        .get(&DataKey::GovDelay)
        .unwrap_or(0)
}

pub fn write_gov_delay(env: &Env, new_gov_delay: u64) {
    env.storage()
        .instance()
        .set(&DataKey::GovDelay, &new_gov_delay);
}

pub fn read_next_gov_delay(env: &Env) -> Option<u64> {
    env.storage().temporary().get(&DataKey::NextGovDelay)
}

pub fn write_next_gov_delay(env: &Env, next: u64) {
    let key = DataKey::NextGovDelay;
    env.storage().temporary().set(&key, &next);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_next_gov_delay(env: &Env) {
    env.storage().temporary().remove(&DataKey::NextGovDelay);
}

pub fn read_et_next_gov_delay(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextGovDelay)
        .unwrap_or(0)
}

pub fn write_et_next_gov_delay(env: &Env, et: u64) {
    let key = DataKey::EtNextGovDelay;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_gov_delay(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextGovDelay);
}

//--------- upgrade ----------

pub fn read_next_upgrade_wasm_hash(env: &Env) -> Option<BytesN<32>> {
    env.storage().temporary().get(&DataKey::NewWasmHash)
}

pub fn write_next_upgrade_wasm_hash(env: &Env, new_wasm_hash: &BytesN<32>) {
    let key = DataKey::NewWasmHash;
    env.storage().temporary().set(&key, new_wasm_hash);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_next_upgrade_wasm_hash(env: &Env) {
    env.storage().temporary().remove(&DataKey::NewWasmHash);
}

pub fn read_et_next_upgrade(env: &Env) -> u64 {
    env.storage()
        .temporary()
        .get(&DataKey::EtNextUpgrade)
        .unwrap_or(0)
}

pub fn write_et_next_upgrade(env: &Env, et: u64) {
    let key = DataKey::EtNextUpgrade;
    env.storage().temporary().set(&key, &et);
    env.storage()
        .temporary()
        .extend_ttl(&key, PENDING_TTL_LEDGERS, PENDING_TTL_LEDGERS);
}

pub fn remove_et_next_upgrade(env: &Env) {
    env.storage().temporary().remove(&DataKey::EtNextUpgrade);
}
