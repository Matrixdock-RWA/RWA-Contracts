use soroban_sdk::{Address, BytesN, Env};

use crate::storage_types::DataKey;

pub fn read_owner(env: &Env) -> Address {
    let key = DataKey::Owner;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_owner(env: &Env, new_owner: &Address) {
    let key = DataKey::Owner;
    env.storage().instance().set(&key, new_owner);
}

pub fn write_pending_owner(env: &Env, addr: &Address) {
    env.storage().instance().set(&DataKey::PendingOwner, addr);
}

pub fn read_pending_owner(env: &Env) -> Option<Address> {
    env.storage().instance().get(&DataKey::PendingOwner)
}

pub fn remove_pending_owner(env: &Env) {
    env.storage().instance().remove(&DataKey::PendingOwner);
}

pub fn read_et_next_owner(env: &Env) -> u64 {
    env.storage()
        .instance()
        .get(&DataKey::EtNextOwner)
        .unwrap_or(0)
}

pub fn write_et_next_owner(env: &Env, et: u64) {
    let key = DataKey::EtNextOwner;
    env.storage().instance().set(&key, &et);
}

//-------- pool account ----------

pub fn read_pool_account_a(env: &Env) -> Address {
    let key = DataKey::PoolAccountA;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_pool_account_a(env: &Env, new_pool: &Address) {
    let key = DataKey::PoolAccountA;
    env.storage().instance().set(&key, new_pool);
}

pub fn read_pool_account_b(env: &Env) -> Address {
    let key = DataKey::PoolAccountB;
    env.storage().instance().get(&key).unwrap()
}

pub fn write_pool_account_b(env: &Env, new_pool: &Address) {
    let key = DataKey::PoolAccountB;
    env.storage().instance().set(&key, new_pool);
}

//-------- accepted by pool ----------
pub fn is_token_accepted_by_a(env: &Env, token: &Address) -> bool {
    let key = DataKey::AcceptedByA(token.clone());
    env.storage().instance().has(&key)
}

pub fn write_token_accepted_by_a(env: &Env, token: &Address) {
    let key = DataKey::AcceptedByA(token.clone());
    env.storage().instance().set(&key, &());
}

pub fn remove_token_accepted_by_a(env: &Env, token: &Address) {
    let key = DataKey::AcceptedByA(token.clone());
    env.storage().instance().remove(&key);
}

pub fn is_token_accepted_by_b(env: &Env, token: &Address) -> bool {
    let key = DataKey::AcceptedByB(token.clone());
    env.storage().instance().has(&key)
}

pub fn write_token_accepted_by_b(env: &Env, token: &Address) {
    let key = DataKey::AcceptedByB(token.clone());
    env.storage().instance().set(&key, &());
}

pub fn remove_token_accepted_by_b(env: &Env, token: &Address) {
    let key = DataKey::AcceptedByB(token.clone());
    env.storage().instance().remove(&key);
}

//--------- upgrade ----------

pub fn read_next_upgrade_wasm_hash(env: &Env) -> Option<BytesN<32>> {
    env.storage().instance().get(&DataKey::NewWasmHash)
}

pub fn write_next_upgrade_wasm_hash(env: &Env, new_wasm_hash: &BytesN<32>) {
    env.storage()
        .instance()
        .set(&DataKey::NewWasmHash, new_wasm_hash);
}

pub fn remove_next_upgrade_wasm_hash(env: &Env) {
    env.storage().instance().remove(&DataKey::NewWasmHash);
}

pub fn read_et_next_upgrade(env: &Env) -> u64 {
    env.storage()
        .instance()
        .get(&DataKey::EtNextUpgrade)
        .unwrap_or(0)
}

pub fn write_et_next_upgrade(env: &Env, et: u64) {
    let key = DataKey::EtNextUpgrade;
    env.storage().instance().set(&key, &et);
}
