use soroban_sdk::token::TokenClient;
use soroban_sdk::{contract, contractimpl, panic_with_error, Address, Bytes, BytesN, Env, Vec};

use crate::error::MinterError;
use crate::events::*;
use crate::state::*;
use crate::storage_types::{INSTANCE_BUMP_AMOUNT, INSTANCE_LIFETIME_THRESHOLD};

#[contract]
pub struct BullionMinter;

const DELAY_MAX: u64 = 59;
const DELAY_SETTING: u64 = 12 * 3600; // 12 hours in seconds

#[contractimpl]
impl BullionMinter {
    // ---------- constructor ----------

    pub fn __constructor(
        env: Env,
        owner: Address,
        pool_a: Address,
        pool_b: Address,
        tokens_accepted_by_a: Vec<Address>,
        tokens_accepted_by_b: Vec<Address>,
    ) {
        write_owner(&env, &owner);
        write_pool_account_a(&env, &pool_a);
        write_pool_account_b(&env, &pool_b);

        // acceptedByA
        for token in tokens_accepted_by_a.iter() {
            write_token_accepted_by_a(&env, &token);
        }

        // acceptedByB
        for token in tokens_accepted_by_b.iter() {
            write_token_accepted_by_b(&env, &token);
        }
    }

    fn require_owner(env: &Env) -> Address {
        let owner: Address = read_owner(env);
        owner.require_auth();
        owner
    }

    pub fn request_upgrade(env: Env, new_wasm_hash: BytesN<32>) {
        let owner = Self::require_owner(&env);

        bump_instance(&env);

        if read_et_next_upgrade(&env) != 0 {
            panic_with_error!(&env, MinterError::PendingRequestExists);
        }

        write_next_upgrade_wasm_hash(&env, &new_wasm_hash);
        let now = env.ledger().timestamp();
        let effective_time = now + DELAY_SETTING;
        write_et_next_upgrade(&env, effective_time);
        UpgradeRequested {
            owner,
            new_wasm_hash,
            effective_time,
        }
        .publish(&env);
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn upgrade(env: Env, new_wasm_hash: BytesN<32>) {
        let owner = Self::require_owner(&env);

        if read_next_upgrade_wasm_hash(&env) != Some(new_wasm_hash.clone()) {
            panic_with_error!(&env, MinterError::InvalidWasmHash);
        }
        let now = env.ledger().timestamp();
        if read_et_next_upgrade(&env) >= now {
            panic_with_error!(&env, MinterError::TooEarlyToExecute);
        }
        env.deployer()
            .update_current_contract_wasm(new_wasm_hash.clone());
        remove_next_upgrade_wasm_hash(&env);
        remove_et_next_upgrade(&env);

        ContractUpgraded {
            owner,
            new_wasm_hash,
        }
        .publish(&env);
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn revoke_next_upgrade(env: Env) {
        let owner = Self::require_owner(&env);

        bump_instance(&env);

        let new_wasm_hash = read_next_upgrade_wasm_hash(&env)
            .unwrap_or_else(|| panic_with_error!(&env, MinterError::NoPendingUpgrade));
        remove_next_upgrade_wasm_hash(&env);
        remove_et_next_upgrade(&env);

        UpgradeRevoked {
            owner,
            new_wasm_hash,
        }
        .publish(&env);
    }

    pub fn request_owner_transfer(env: Env, new_owner: Address) {
        let owner = Self::require_owner(&env);
        bump_instance(&env);

        if read_et_next_owner(&env) != 0 {
            panic_with_error!(&env, MinterError::PendingRequestExists);
        }

        write_pending_owner(&env, &new_owner);
        let now = env.ledger().timestamp();
        let effective_time = now + DELAY_SETTING;
        write_et_next_owner(&env, effective_time);
        OwnerTransferRequested {
            owner,
            pending_owner: new_owner,
            effective_time,
        }
        .publish(&env);
    }

    pub fn accept_owner(env: Env) {
        let pending_owner = read_pending_owner(&env)
            .unwrap_or_else(|| panic_with_error!(&env, MinterError::NoPendingOwner));

        pending_owner.require_auth();

        bump_instance(&env);
        let now = env.ledger().timestamp();
        if read_et_next_owner(&env) >= now {
            panic_with_error!(&env, MinterError::TooEarlyToExecute);
        }
        let old_owner = read_owner(&env);

        write_owner(&env, &pending_owner);
        remove_pending_owner(&env);
        remove_et_next_owner(&env);
        OwnerTransferred {
            old_owner,
            new_owner: pending_owner,
        }
        .publish(&env);
    }

    pub fn revoke_next_owner(env: Env) {
        Self::require_owner(&env);

        remove_et_next_owner(&env);
        OwnerRevoked {}.publish(&env);
    }

    pub fn set_pool_account_a(env: Env, pool: Address) {
        Self::require_owner(&env);
        bump_instance(&env);
        write_pool_account_a(&env, &pool);
        SetPoolAccountA { pool }.publish(&env);
    }

    pub fn set_pool_account_b(env: Env, pool: Address) {
        Self::require_owner(&env);
        bump_instance(&env);
        write_pool_account_b(&env, &pool);
        SetPoolAccountB { pool }.publish(&env);
    }

    pub fn set_accepted_by_a(env: Env, token: Address, accepted: bool) {
        Self::require_owner(&env);
        bump_instance(&env);
        if accepted {
            write_token_accepted_by_a(&env, &token);
        } else {
            remove_token_accepted_by_a(&env, &token);
        }
        SetAcceptedByA { token, accepted }.publish(&env);
    }

    pub fn set_accepted_by_b(env: Env, token: Address, accepted: bool) {
        Self::require_owner(&env);
        bump_instance(&env);
        if accepted {
            write_token_accepted_by_b(&env, &token);
        } else {
            remove_token_accepted_by_b(&env, &token);
        }
        SetAcceptedByB { token, accepted }.publish(&env);
    }

    pub fn request_to_mint(
        env: Env,
        user: Address,
        transferred_token: Address,
        for_token: Address,
        amount: i128,
        preprice: u128,
        slippage: u128,
        timestamp: u64,
        extra_data: Bytes,
    ) {
        user.require_auth();
        check_nonnegative_amount(&env, amount);
        bump_instance(&env);
        let mut accepted: bool = is_token_accepted_by_a(&env, &transferred_token);
        if !accepted {
            panic_with_error!(env, MinterError::InvalidTokenForMinting);
        }

        accepted = is_token_accepted_by_b(&env, &for_token);
        if !accepted {
            panic_with_error!(env, MinterError::InvalidForToken);
        }

        let now = env.ledger().timestamp();
        if now > timestamp + DELAY_MAX {
            panic_with_error!(env, MinterError::InvalidTimestamp);
        }

        let pool: Address = read_pool_account_a(&env);
        let token = TokenClient::new(&env, &transferred_token);
        token.transfer(&user, &pool, &amount);

        MintRequest {
            transferred_token,
            for_token,
            requestor: user,
            pool,
            amount,
            preprice,
            slippage,
            extra_data,
        }
        .publish(&env);
    }

    pub fn request_to_redeem(
        env: Env,
        user: Address,
        transferred_token: Address,
        for_token: Address,
        amount: i128,
        preprice: u128,
        slippage: u128,
        timestamp: u64,
        extra_data: Bytes,
    ) {
        user.require_auth();
        check_nonnegative_amount(&env, amount);
        bump_instance(&env);
        let mut accepted: bool = is_token_accepted_by_b(&env, &transferred_token);
        if !accepted {
            panic_with_error!(env, MinterError::InvalidTokenForRedeeming);
        }

        accepted = is_token_accepted_by_a(&env, &for_token);
        if !accepted {
            panic_with_error!(env, MinterError::InvalidForToken);
        }

        let now = env.ledger().timestamp();
        if now > timestamp + DELAY_MAX {
            panic_with_error!(env, MinterError::InvalidTimestamp);
        }

        let pool: Address = read_pool_account_b(&env);
        let token = TokenClient::new(&env, &transferred_token);
        token.transfer(&user, &pool, &amount);

        RedeemRequest {
            transferred_token,
            for_token,
            requestor: user,
            pool,
            amount,
            preprice,
            slippage,
            extra_data,
        }
        .publish(&env);
    }

    pub fn owner(env: Env) -> Address {
        read_owner(&env)
    }

    pub fn pending_owner(env: Env) -> Option<Address> {
        read_pending_owner(&env)
    }

    pub fn et_next_owner(env: Env) -> Option<u64> {
        match read_et_next_owner(&env) {
            0 => None,
            val => Some(val),
        }
    }

    pub fn pool_account_a(env: Env) -> Address {
        read_pool_account_a(&env)
    }

    pub fn pool_account_b(env: Env) -> Address {
        read_pool_account_b(&env)
    }

    pub fn is_accepted_by_a(env: Env, token: Address) -> bool {
        is_token_accepted_by_a(&env, &token)
    }

    pub fn is_accepted_by_b(env: Env, token: Address) -> bool {
        is_token_accepted_by_b(&env, &token)
    }

    pub fn next_upgrade_wasm_hash(env: Env) -> Option<BytesN<32>> {
        read_next_upgrade_wasm_hash(&env)
    }

    pub fn et_next_upgrade(env: Env) -> Option<u64> {
        match read_et_next_upgrade(&env) {
            0 => None,
            val => Some(val),
        }
    }
}

fn bump_instance(env: &Env) {
    env.storage()
        .instance()
        .extend_ttl(INSTANCE_LIFETIME_THRESHOLD, INSTANCE_BUMP_AMOUNT);
}

fn check_nonnegative_amount(env: &Env, amount: i128) {
    if amount < 0 {
        panic_with_error!(env, MinterError::NegativeAmountNotAllowed);
    }
}
