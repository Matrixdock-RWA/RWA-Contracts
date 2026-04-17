use crate::error::TokenError;
use crate::state;
use crate::storage_types::{DataKey, BALANCE_BUMP_AMOUNT, BALANCE_LIFETIME_THRESHOLD};
use soroban_sdk::{panic_with_error, Address, Env};

pub fn read_balance(e: &Env, addr: Address) -> i128 {
    let key = DataKey::Balance(addr);
    if let Some(balance) = e.storage().persistent().get::<DataKey, i128>(&key) {
        e.storage()
            .persistent()
            .extend_ttl(&key, BALANCE_LIFETIME_THRESHOLD, BALANCE_BUMP_AMOUNT);
        balance
    } else {
        0
    }
}

fn write_balance(e: &Env, addr: Address, amount: i128) {
    let key = DataKey::Balance(addr);
    e.storage().persistent().set(&key, &amount);
    e.storage()
        .persistent()
        .extend_ttl(&key, BALANCE_LIFETIME_THRESHOLD, BALANCE_BUMP_AMOUNT);
}

pub fn update_balance(env: &Env, from: Option<Address>, to: Option<Address>, amount: i128) {
    spend_balance(env, from, amount);
    receive_balance(env, to, amount);
}

// amount negativity checked outside
fn receive_balance(env: &Env, to: Option<Address>, amount: i128) {
    if let Some(account) = to {
        let balance = read_balance(env, account.clone());
        write_balance(env, account, balance + amount);
    } else {
        // `to` is None, so we're burning tokens.
        let total_supply = state::read_total_supply(env);
        if amount > total_supply {
            panic_with_error!(env, TokenError::TotalSupplyUnderflow);
        }
        state::write_total_supply(env, total_supply - amount);
    }
}

// amount negativity checked outside
fn spend_balance(env: &Env, from: Option<Address>, amount: i128) {
    if let Some(account) = from {
        let balance = read_balance(env, account.clone());
        if amount > balance {
            panic_with_error!(&env, TokenError::InsufficientBalance);
        }
        write_balance(env, account, balance - amount);
    } else {
        // `from` is None, so we're minting tokens.
        let total_supply = state::read_total_supply(env);
        state::write_total_supply(env, total_supply + amount);
    }
}
