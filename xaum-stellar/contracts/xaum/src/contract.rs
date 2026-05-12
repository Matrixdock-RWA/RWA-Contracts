use crate::allowance::{read_allowance, spend_allowance, write_allowance};
use crate::balance::{read_balance, update_balance};
use crate::error::TokenError;
use crate::metadata::{read_decimal, read_name, read_symbol, write_metadata};
use crate::state;
use crate::storage_types::{INSTANCE_BUMP_AMOUNT, INSTANCE_LIFETIME_THRESHOLD};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    contract, contractevent, contractimpl, panic_with_error, token::TokenInterface, Address, Bytes,
    BytesN, Env, MuxedAddress, String,
};
use soroban_token_sdk::events;
use soroban_token_sdk::metadata::TokenMetadata;

#[cfg(test)]
use crate::storage_types::{AllowanceDataKey, AllowanceValue, DataKey};

const MIN_DELAY: u64 = 3600; // 1hour
const MAX_DELAY: u64 = 3600 * 24 * 7; // 7days

#[contract]
pub struct Token;

#[contractimpl]
impl Token {
    pub fn __constructor(
        env: Env,
        owner: Address,
        operator: Address,
        revoker: Address,
        decimal: u32,
        name: String,
        symbol: String,
    ) {
        if decimal > 18 {
            panic_with_error!(&env, TokenError::InvalidDecimal);
        }
        state::write_owner(&env, &owner);
        state::write_operator(&env, &operator);
        state::write_revoker(&env, &revoker);
        write_metadata(
            &env,
            TokenMetadata {
                decimal,
                name,
                symbol,
            },
        )
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn request_upgrade(env: Env, new_wasm_hash: BytesN<32>) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        state::write_next_upgrade_wasm_hash(&env, &new_wasm_hash);
        let now = env.ledger().timestamp();
        let delay = state::read_delay(&env);
        let effective_time = now + delay;
        state::write_et_next_upgrade(&env, effective_time);
        UpgradeRequested {
            owner,
            new_wasm_hash,
            effective_time,
        }
        .publish(&env);
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn upgrade(env: Env, new_wasm_hash: BytesN<32>) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        if state::read_next_upgrade_wasm_hash(&env) != Some(new_wasm_hash.clone()) {
            panic_with_error!(&env, TokenError::InvalidWasmHash);
        }
        let now = env.ledger().timestamp();
        if state::read_et_next_upgrade(&env) > now {
            panic_with_error!(&env, TokenError::TooEarlyToExecute);
        }
        env.deployer()
            .update_current_contract_wasm(new_wasm_hash.clone());
        state::remove_next_upgrade_wasm_hash(&env);
        state::write_et_next_upgrade(&env, 0);

        ContractUpgraded {
            owner,
            new_wasm_hash,
        }
        .publish(&env);
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn revoke_next_upgrade(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        let new_wasm_hash = state::read_next_upgrade_wasm_hash(&env)
            .unwrap_or_else(|| panic_with_error!(&env, TokenError::NoPendingUpgrade));
        state::remove_next_upgrade_wasm_hash(&env);
        state::write_et_next_upgrade(&env, 0);

        UpgradeRevoked {
            owner,
            new_wasm_hash,
        }
        .publish(&env);
    }

    pub fn request_owner_transfer(env: Env, new_owner: Address) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        state::write_pending_owner(&env, &new_owner);
        let now = env.ledger().timestamp();
        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;
        state::write_et_next_owner(&env, effective_time);
        OwnerTransferRequested {
            owner,
            pending_owner: new_owner,
            effective_time,
        }
        .publish(&env);
    }

    pub fn accept_owner(env: Env) {
        let pending_owner = state::read_pending_owner(&env)
            .unwrap_or_else(|| panic_with_error!(&env, TokenError::NoPendingOwner));

        pending_owner.require_auth();

        bump_instance(&env);
        let now = env.ledger().timestamp();
        if state::read_et_next_owner(&env) > now {
            panic_with_error!(&env, TokenError::TooEarlyToExecute);
        }
        let old_owner = state::read_owner(&env);

        state::write_owner(&env, &pending_owner);
        state::remove_pending_owner(&env);
        state::write_et_next_owner(&env, 0);
        OwnerTransferred {
            old_owner,
            new_owner: pending_owner,
        }
        .publish(&env);
    }

    pub fn revoke_next_owner(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        state::write_et_next_owner(&env, 0);
        OwnerRevoked {}.publish(&env);
    }

    pub fn set_operator(env: Env, new_operator: Address) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        let now = env.ledger().timestamp();

        let current_operator = state::read_operator(&env);
        let next_operator = state::read_next_operator(&env); // Option<Address>
        let et = state::read_et_next_operator(&env); // u64, 0 = none

        if et != 0 {
            // next_operator always be Some if et != 0, no need to check
            if next_operator.unwrap() != new_operator {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et > now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_operator(&env, &new_operator);
            state::write_et_next_operator(&env, 0);
            SetOperatorEffected {
                operator: new_operator,
            }
            .publish(&env);
            return;
        }

        let delay = state::read_delay(&env);
        let effective_time = now + delay;

        state::write_next_operator(&env, &new_operator);
        state::write_et_next_operator(&env, effective_time);

        SetOperatorRequest {
            current_operator,
            next_operator: new_operator,
            effective_time,
        }
        .publish(&env);
    }

    pub fn set_revoker(env: Env, new_revoker: Address) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        let now = env.ledger().timestamp();

        let current_revoker = state::read_revoker(&env);
        let next_revoker = state::read_next_revoker(&env); // Option<Address>
        let et = state::read_et_next_revoker(&env); // u64, 0 = none

        if et != 0 {
            if next_revoker.unwrap() != new_revoker {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et > now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_revoker(&env, &new_revoker);
            state::write_et_next_revoker(&env, 0);
            SetRevokerEffected {
                revoker: new_revoker,
            }
            .publish(&env);
            return;
        }

        let delay = state::read_delay(&env);
        let effective_time = now + delay;

        state::write_next_revoker(&env, &new_revoker);
        state::write_et_next_revoker(&env, effective_time);

        SetRevokerRequest {
            current_revoker,
            next_revoker: new_revoker,
            effective_time,
        }
        .publish(&env);
    }

    pub fn set_delay(env: Env, new_delay: u64) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        if new_delay < MIN_DELAY {
            panic_with_error!(&env, TokenError::DelayTooSmall);
        }
        if new_delay > MAX_DELAY {
            panic_with_error!(&env, TokenError::DelayTooLarge);
        }
        let now = env.ledger().timestamp();

        let current_delay = state::read_delay(&env);
        let next_delay = state::read_next_delay(&env); // Option<u64>
        let et = state::read_et_next_delay(&env); // u64, 0 = none

        if et != 0 {
            if next_delay.unwrap() != new_delay {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et > now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_delay(&env, new_delay);
            state::write_et_next_delay(&env, 0);
            SetDelayEffected { delay: new_delay }.publish(&env);
            return;
        }

        let delay = state::read_delay(&env);
        let effective_time = now + delay;

        state::write_next_delay(&env, new_delay);
        state::write_et_next_delay(&env, effective_time);

        SetDelayRequest {
            current_delay,
            next_delay: new_delay,
            effective_time,
        }
        .publish(&env);
    }

    pub fn set_gov_delay(env: Env, new_delay: u64) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        if new_delay < MIN_DELAY {
            panic_with_error!(&env, TokenError::DelayTooSmall);
        }
        if new_delay > MAX_DELAY {
            panic_with_error!(&env, TokenError::DelayTooLarge);
        }
        let now = env.ledger().timestamp();

        let current_delay = state::read_gov_delay(&env);
        let next_delay = state::read_next_gov_delay(&env); // Option<u64>
        let et = state::read_et_next_gov_delay(&env); // u64, 0 = none

        if et != 0 {
            if next_delay.unwrap() != new_delay {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et > now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_gov_delay(&env, new_delay);
            state::write_et_next_gov_delay(&env, 0);
            SetGovDelayEffected { delay: new_delay }.publish(&env);
            return;
        }

        let delay = state::read_gov_delay(&env);
        let effective_time = now + delay;

        state::write_next_gov_delay(&env, new_delay);
        state::write_et_next_gov_delay(&env, effective_time);

        SetGovDelayRequest {
            current_delay,
            next_delay: new_delay,
            effective_time,
        }
        .publish(&env);
    }

    // owner auth required to revoke pending gov delay change here
    pub fn revoke_next_gov_delay(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();
        state::write_et_next_gov_delay(&env, 0);
        GovDelayRevoked {}.publish(&env);
    }

    pub fn revoke_next_delay(env: Env) {
        let revoker = state::read_revoker(&env);
        revoker.require_auth();
        state::write_et_next_delay(&env, 0);
        DelayRevoked {}.publish(&env);
    }

    pub fn revoke_next_operator(env: Env) {
        let revoker = state::read_revoker(&env);
        revoker.require_auth();
        state::write_et_next_operator(&env, 0);
        OperatorRevoked {}.publish(&env);
    }

    pub fn revoke_next_revoker(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();
        state::write_et_next_revoker(&env, 0);
        RevokerRevoked {}.publish(&env);
    }

    pub fn change_mint_budget(env: Env, delta: i128) {
        // onlyOperator
        let operator = state::read_operator(&env);
        operator.require_auth();

        bump_instance(&env);

        let mint_budget = state::read_mint_budget(&env);

        let new_budget = mint_budget + delta;
        if new_budget < 0 {
            panic_with_error!(&env, TokenError::MintBudgetNotEnough);
        }
        state::write_mint_budget(&env, new_budget);
        ChangeMintBudget { delta }.publish(&env);
    }

    pub fn mint_to(env: Env, receiver: Address, amount: i128, nonce: u64) -> bool {
        let operator = state::read_operator(&env);
        operator.require_auth();
        check_nonnegative_amount(&env, amount);

        bump_instance(&env);

        let mut bytes = Bytes::new(&env);

        // 1. receiver: Address -> XDR bytes
        bytes.append(&receiver.clone().to_xdr(&env));

        // 2. amount: i128 -> 16 bytes (big-endian)
        bytes.append(&Bytes::from_slice(&env, &amount.to_be_bytes()));

        // 3. nonce: u64 -> 8 bytes (big-endian)
        bytes.append(&Bytes::from_slice(&env, &nonce.to_be_bytes()));

        // sha256
        let req: BytesN<32> = env.crypto().sha256(&bytes).into();

        let now = env.ledger().timestamp();
        let delay = state::read_delay(&env);

        match state::read_mint_request(&env, &req) {
            None => {
                // first call: register request
                let et = now + delay;
                state::write_mint_request(&env, &req, et);
                MintRequest {
                    receiver,
                    amount,
                    nonce,
                    et,
                }
                .publish(&env);
                false
            }
            Some(et) => {
                if et > now {
                    panic_with_error!(&env, TokenError::TooEarlyToExecute);
                }
                state::remove_mint_request(&env, &req);
                // budget check
                let budget = state::read_mint_budget(&env);
                if amount > budget {
                    panic_with_error!(&env, TokenError::MintBudgetNotEnough);
                }
                state::write_mint_budget(&env, budget - amount);
                // mint
                update_balance(&env, None, Some(receiver.clone()), amount);
                events::MintWithAmountOnly {
                    to: receiver.clone(),
                    amount,
                }
                .publish(&env);
                MintEffected {
                    receiver,
                    amount,
                    nonce,
                }
                .publish(&env);
                true
            }
        }
    }

    pub fn revoke_mint_request(env: Env, req: BytesN<32>) {
        let revoker = state::read_revoker(&env);
        revoker.require_auth();

        state::remove_mint_request(&env, &req);
        MintRequestRevoked { req }.publish(&env);
    }

    pub fn add_to_blocked_list(env: Env, user: Address) {
        let operator = state::read_operator(&env);
        operator.require_auth();

        bump_instance(&env);

        state::write_blocked(&env, &user, true);
        BlockPlaced { user }.publish(&env);
    }

    pub fn remove_from_blocked_list(env: Env, user: Address) {
        let operator = state::read_operator(&env);
        operator.require_auth();

        bump_instance(&env);

        state::write_blocked(&env, &user, false);
        BlockReleased { user }.publish(&env);
    }

    // ---------- getters ----------

    pub fn owner(env: Env) -> Address {
        state::read_owner(&env)
    }

    pub fn pending_owner(env: Env) -> Option<Address> {
        state::read_pending_owner(&env)
    }

    pub fn et_next_owner(env: Env) -> u64 {
        state::read_et_next_owner(&env)
    }

    pub fn operator(env: Env) -> Address {
        state::read_operator(&env)
    }

    pub fn next_operator(env: Env) -> Option<Address> {
        state::read_next_operator(&env)
    }

    pub fn et_next_operator(env: Env) -> u64 {
        state::read_et_next_operator(&env)
    }

    pub fn revoker(env: Env) -> Address {
        state::read_revoker(&env)
    }

    pub fn next_revoker(env: Env) -> Option<Address> {
        state::read_next_revoker(&env)
    }

    pub fn et_next_revoker(env: Env) -> u64 {
        state::read_et_next_revoker(&env)
    }

    pub fn delay(env: Env) -> u64 {
        state::read_delay(&env)
    }

    pub fn next_delay(env: Env) -> u64 {
        state::read_next_delay(&env).unwrap_or(0)
    }

    pub fn et_next_delay(env: Env) -> u64 {
        state::read_et_next_delay(&env)
    }

    pub fn gov_delay(env: Env) -> u64 {
        state::read_gov_delay(&env)
    }

    pub fn next_gov_delay(env: Env) -> u64 {
        state::read_next_gov_delay(&env).unwrap_or(0)
    }

    pub fn et_next_gov_delay(env: Env) -> u64 {
        state::read_et_next_gov_delay(&env)
    }

    pub fn next_upgrade_wasm_hash(env: Env) -> Option<BytesN<32>> {
        state::read_next_upgrade_wasm_hash(&env)
    }

    pub fn et_next_upgrade(env: Env) -> u64 {
        state::read_et_next_upgrade(&env)
    }

    pub fn mint_budget(env: Env) -> i128 {
        state::read_mint_budget(&env)
    }

    pub fn mint_request_et(env: Env, req: BytesN<32>) -> u64 {
        state::read_mint_request(&env, &req).unwrap_or(0)
    }

    pub fn is_blocked(env: Env, user: Address) -> bool {
        state::is_blocked(&env, &user)
    }

    pub fn total_supply(env: Env) -> i128 {
        state::read_total_supply(&env)
    }

    #[cfg(test)]
    pub fn get_allowance(env: Env, from: Address, spender: Address) -> Option<AllowanceValue> {
        let key = DataKey::Allowance(AllowanceDataKey { from, spender });
        let allowance = env.storage().temporary().get::<_, AllowanceValue>(&key);
        allowance
    }
}

#[contractimpl]
impl TokenInterface for Token {
    fn allowance(env: Env, from: Address, spender: Address) -> i128 {
        bump_instance(&env);
        read_allowance(&env, from, spender).amount
    }

    fn approve(env: Env, from: Address, spender: Address, amount: i128, expiration_ledger: u32) {
        from.require_auth();
        check_nonnegative_amount(&env, amount);

        bump_instance(&env);

        write_allowance(
            &env,
            from.clone(),
            spender.clone(),
            amount,
            expiration_ledger,
        );
        events::Approve {
            from,
            spender,
            amount,
            expiration_ledger,
        }
        .publish(&env);
    }

    fn balance(env: Env, id: Address) -> i128 {
        bump_instance(&env);
        read_balance(&env, id)
    }

    fn transfer(env: Env, from: Address, to_muxed: MuxedAddress, amount: i128) {
        from.require_auth();
        require_not_blocked(&env, &from);
        check_nonnegative_amount(&env, amount);

        bump_instance(&env);

        let to: Address = to_muxed.address();
        update_balance(&env, Some(from.clone()), Some(to.clone()), amount);
        events::Transfer {
            from,
            to,
            to_muxed_id: to_muxed.id(),
            amount,
        }
        .publish(&env);
    }

    fn transfer_from(env: Env, spender: Address, from: Address, to: Address, amount: i128) {
        spender.require_auth();
        require_not_blocked(&env, &spender);
        require_not_blocked(&env, &from);
        check_nonnegative_amount(&env, amount);

        bump_instance(&env);

        spend_allowance(&env, from.clone(), spender, amount);
        update_balance(&env, Some(from.clone()), Some(to.clone()), amount);
        events::Transfer {
            from,
            to,
            // `transfer_from` does not support muxed destination.
            to_muxed_id: None,
            amount,
        }
        .publish(&env);
    }

    fn burn(env: Env, from: Address, amount: i128) {
        let operator = state::read_operator(&env);
        operator.require_auth();
        check_nonnegative_amount(&env, amount);
        bump_instance(&env);

        update_balance(&env, Some(operator.clone()), None, amount);
        let budget = state::read_mint_budget(&env);
        state::write_mint_budget(&env, budget + amount);
        events::Burn {
            from: operator,
            amount,
        }
        .publish(&env);
        Redeem {
            customer: from,
            amount,
        }
        .publish(&env);
    }

    fn burn_from(env: Env, _spender: Address, _from: Address, _amount: i128) {
        panic_with_error!(&env, TokenError::NotSupported);
    }

    fn decimals(env: Env) -> u32 {
        read_decimal(&env)
    }

    fn name(env: Env) -> String {
        read_name(&env)
    }

    fn symbol(env: Env) -> String {
        read_symbol(&env)
    }
}

//---------- events ----------

#[contractevent]
pub struct OwnerTransferRequested {
    pub owner: Address,
    pub pending_owner: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct OwnerTransferred {
    pub old_owner: Address,
    pub new_owner: Address,
}

#[contractevent]
pub struct SetOperatorEffected {
    pub operator: Address,
}

#[contractevent]
pub struct SetOperatorRequest {
    pub current_operator: Address,
    pub next_operator: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct SetRevokerEffected {
    pub revoker: Address,
}

#[contractevent]
pub struct SetRevokerRequest {
    pub current_revoker: Address,
    pub next_revoker: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct SetDelayEffected {
    pub delay: u64,
}

#[contractevent]
pub struct SetDelayRequest {
    pub current_delay: u64,
    pub next_delay: u64,
    pub effective_time: u64,
}

#[contractevent]
pub struct ChangeMintBudget {
    pub delta: i128,
}

#[contractevent]
pub struct MintRequest {
    #[topic]
    pub receiver: Address,
    pub amount: i128,
    pub nonce: u64,
    pub et: u64,
}

#[contractevent]
pub struct MintEffected {
    #[topic]
    pub receiver: Address,
    pub amount: i128,
    pub nonce: u64,
}

#[contractevent]
pub struct BlockPlaced {
    #[topic]
    pub user: Address,
}

#[contractevent]
pub struct BlockReleased {
    #[topic]
    pub user: Address,
}

#[contractevent]
pub struct Redeem {
    #[topic]
    pub customer: Address,
    pub amount: i128,
}

#[contractevent]
pub struct SetGovDelayEffected {
    pub delay: u64,
}

#[contractevent]
pub struct SetGovDelayRequest {
    pub current_delay: u64,
    pub next_delay: u64,
    pub effective_time: u64,
}

#[contractevent]
pub struct UpgradeRequested {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
    pub effective_time: u64,
}

#[contractevent]
pub struct ContractUpgraded {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
}

#[contractevent]
pub struct UpgradeRevoked {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
}

#[contractevent]
pub struct GovDelayRevoked {}

#[contractevent]
pub struct DelayRevoked {}

#[contractevent]
pub struct OperatorRevoked {}

#[contractevent]
pub struct RevokerRevoked {}

#[contractevent]
pub struct OwnerRevoked {}

#[contractevent]
pub struct MintRequestRevoked {
    pub req: BytesN<32>,
}

//---------- utility functions ----------
fn require_not_blocked(env: &Env, user: &Address) {
    if state::is_blocked(env, user) {
        panic_with_error!(&env, TokenError::UserBlocked);
    }
}

fn check_nonnegative_amount(env: &Env, amount: i128) {
    if amount < 0 {
        panic_with_error!(env, TokenError::NegativeAmountNotAllowed);
    }
}

fn bump_instance(env: &Env) {
    env.storage()
        .instance()
        .extend_ttl(INSTANCE_LIFETIME_THRESHOLD, INSTANCE_BUMP_AMOUNT);
}
