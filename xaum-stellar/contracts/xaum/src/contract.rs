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

// Governance-level timelock: bounds control-plane changes (roles, rules, upgrade).
const MIN_GOV_DELAY: u64 = 3600 * 24; // 24 hours
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7 days
// Operational-level timelock: bounds day-to-day fund/role operations.
const MIN_DELAY: u64 = 3600; // 1 hour
const MAX_DELAY: u64 = 3600 * 24 * 2; // 48 hours
pub(crate) const SHARED_DECIMALS: u32 = 9;

// The canonical EVM relay represents both cumulative watermarks as uint112. Keep the
// Stellar endpoint in the same domain even though Soroban token amounts use i128, or a
// return recorded here could be impossible to submit to reclaimMintBudgetFromChain.
const MAX_MINT_BUDGET_RELAY_AMOUNT: i128 = (1_i128 << 112) - 1;

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
        if decimal != SHARED_DECIMALS {
            panic_with_error!(&env, TokenError::InvalidDecimal);
        }
        state::write_owner(&env, &owner);
        state::write_operator(&env, &operator);
        state::write_revoker(&env, &revoker);
        // gov_delay/delay are deliberately left at 0 (timelocks disarmed) so the deployer
        // can complete wiring and ownership handover without waiting. They are armed later
        // via set_gov_delay then set_delay.
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

        if state::read_et_next_upgrade(&env).is_some() {
            panic_with_error!(&env, TokenError::PendingRequestExists);
        }

        state::write_next_upgrade_wasm_hash(&env, &new_wasm_hash);
        let now = env.ledger().timestamp();
        // upgrade = arbitrary code = all assets: governance-level timelock
        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;
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
        match state::read_et_next_upgrade(&env) {
            Some(et) if et < now => {}
            _ => panic_with_error!(&env, TokenError::TooEarlyToExecute),
        }
        env.deployer()
            .update_current_contract_wasm(new_wasm_hash.clone());
        state::remove_next_upgrade_wasm_hash(&env);
        state::remove_et_next_upgrade(&env);

        ContractUpgraded {
            owner,
            new_wasm_hash,
        }
        .publish(&env);
    }

    // WARNING!!! Upgrade Support Function must always here in any version of contract, otherwise the contract will be locked forever.
    pub fn revoke_next_upgrade(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);

        bump_instance(&env);

        // Always emit, matching every other revoke op. Emit the real pending hash when one
        // existed (and clear it), otherwise an all-zero BytesN<32> sentinel, so monitoring can
        // distinguish a real revoke from an anomalous/no-pending revoke. Event schema is
        // unchanged (contract already deployed): new_wasm_hash stays BytesN<32>.
        let new_wasm_hash = match state::read_next_upgrade_wasm_hash(&env) {
            Some(hash) => {
                state::remove_next_upgrade_wasm_hash(&env);
                state::remove_et_next_upgrade(&env);
                hash
            }
            None => BytesN::from_array(&env, &[0u8; 32]),
        };

        UpgradeRevoked {
            caller,
            new_wasm_hash,
        }
        .publish(&env);
    }

    pub fn request_owner_transfer(env: Env, new_owner: Address) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        if state::read_et_next_owner(&env).is_some() {
            panic_with_error!(&env, TokenError::PendingRequestExists);
        }

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
        match state::read_et_next_owner(&env) {
            Some(et) if et < now => {}
            _ => panic_with_error!(&env, TokenError::TooEarlyToExecute),
        }
        let old_owner = state::read_owner(&env);

        state::write_owner(&env, &pending_owner);
        state::remove_pending_owner(&env);
        state::remove_et_next_owner(&env);
        OwnerTransferred {
            old_owner,
            new_owner: pending_owner,
        }
        .publish(&env);
    }

    pub fn revoke_next_owner(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);

        state::remove_pending_owner(&env);
        state::remove_et_next_owner(&env);
        OwnerRevoked {}.publish(&env);
    }

    pub fn set_operator(env: Env, new_operator: Address) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        check_operator_submitter_distinct(
            &env,
            &new_operator,
            &state::read_mint_budget_submitter(&env),
        );

        let now = env.ledger().timestamp();

        let current_operator = state::read_operator(&env);
        let next_operator = state::read_next_operator(&env); // Option<Address>

        if let Some(et) = state::read_et_next_operator(&env) {
            // next_operator is always Some while a request is pending, no need to check
            if next_operator.unwrap() != new_operator {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et >= now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_operator(&env, &new_operator);
            state::remove_et_next_operator(&env);
            state::remove_next_operator(&env);
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

    // setRevoker (#1): governance-level timelock, two-step accept.
    // Owner requests; after gov_delay the new revoker accepts in person (guards against
    // typo'd / dead addresses). Revocable by owner-or-operator (never by revoker itself).
    pub fn request_set_revoker(env: Env, new_revoker: Address) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        if state::read_et_next_revoker(&env).is_some() {
            panic_with_error!(&env, TokenError::PendingRequestExists);
        }

        let current_revoker = state::read_revoker(&env);
        state::write_next_revoker(&env, &new_revoker);
        let now = env.ledger().timestamp();
        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;
        state::write_et_next_revoker(&env, effective_time);

        SetRevokerRequest {
            current_revoker,
            next_revoker: new_revoker,
            effective_time,
        }
        .publish(&env);
    }

    pub fn accept_revoker(env: Env) {
        let next_revoker = state::read_next_revoker(&env)
            .unwrap_or_else(|| panic_with_error!(&env, TokenError::NoPendingRevoker));
        next_revoker.require_auth();

        bump_instance(&env);
        let now = env.ledger().timestamp();
        match state::read_et_next_revoker(&env) {
            Some(et) if et < now => {}
            _ => panic_with_error!(&env, TokenError::TooEarlyToExecute),
        }
        state::write_revoker(&env, &next_revoker);
        state::remove_next_revoker(&env);
        state::remove_et_next_revoker(&env);
        SetRevokerEffected {
            revoker: next_revoker,
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
        // invariant: gov_delay >= delay must always hold
        if new_delay > state::read_gov_delay(&env) {
            panic_with_error!(&env, TokenError::DelayExceedsGovDelay);
        }
        let now = env.ledger().timestamp();

        let current_delay = state::read_delay(&env);
        let next_delay = state::read_next_delay(&env); // Option<u64>

        if let Some(et) = state::read_et_next_delay(&env) {
            // next_delay is always Some while a request is pending, no need to check
            if next_delay.unwrap() != new_delay {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et >= now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            // Re-validate the invariant against the *currently effective* gov_delay:
            // a set_gov_delay request may have matured and lowered gov_delay after this
            // request was staged, so the request-path check is not sufficient. Current
            // effective state is authoritative; do not inspect the counterpart pending
            // value. Panic before writing so the pending request survives for revoke.
            if new_delay > state::read_gov_delay(&env) {
                panic_with_error!(&env, TokenError::DelayExceedsGovDelay);
            }
            state::write_delay(&env, new_delay);
            state::remove_et_next_delay(&env);
            state::remove_next_delay(&env);
            SetDelayEffected { delay: new_delay }.publish(&env);
            return;
        }

        // setDelay is protected by gov_delay (staging principle: can't shorten delay quickly)
        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;

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

        if new_delay < MIN_GOV_DELAY {
            panic_with_error!(&env, TokenError::GovDelayTooSmall);
        }
        if new_delay > MAX_GOV_DELAY {
            panic_with_error!(&env, TokenError::GovDelayTooLarge);
        }
        // invariant: gov_delay >= delay must always hold
        if new_delay < state::read_delay(&env) {
            panic_with_error!(&env, TokenError::GovDelayBelowDelay);
        }
        let now = env.ledger().timestamp();

        let current_delay = state::read_gov_delay(&env);
        let next_delay = state::read_next_gov_delay(&env); // Option<u64>

        if let Some(et) = state::read_et_next_gov_delay(&env) {
            // next_gov_delay is always Some while a request is pending, no need to check
            if next_delay.unwrap() != new_delay {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et >= now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            // Re-validate the invariant against the *currently effective* delay:
            // a set_delay request may have matured and raised delay after this request
            // was staged, so the request-path check is not sufficient. Current effective
            // state is authoritative; do not inspect the counterpart pending value.
            // Panic before writing so the pending request survives for revoke.
            if new_delay < state::read_delay(&env) {
                panic_with_error!(&env, TokenError::GovDelayBelowDelay);
            }
            state::write_gov_delay(&env, new_delay);
            state::remove_et_next_gov_delay(&env);
            state::remove_next_gov_delay(&env);
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

    pub fn revoke_next_gov_delay(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_gov_delay(&env);
        state::remove_next_gov_delay(&env);
        GovDelayRevoked {}.publish(&env);
    }

    // forced_transfer (#13): monitored/clawback transfer, delay tier, two-call pattern (like mint_to).
    // Constraints: `from` must already be blocked (freeze precedes clawback); `to` is locked to the
    // configured forced-transfer receiver. Deliberately NOT subject to pause nor to the block-send
    // limit, so clawback stays possible while paused. Per-request revoke by owner-or-revoker.
    // note: nonce lets identical (from, amount, data) transfers be requested independently.
    pub fn forced_transfer(
        env: Env,
        from: Address,
        to: Address,
        amount: i128,
        nonce: u64,
        data: String,
        extra_data: String,
    ) -> bool {
        let owner = state::read_owner(&env);
        owner.require_auth();
        check_nonnegative_amount(&env, amount);

        bump_instance(&env);

        if !state::is_blocked(&env, &from) {
            panic_with_error!(&env, TokenError::NotBlocked);
        }
        let receiver = state::read_forced_transfer_receiver(&env)
            .unwrap_or_else(|| panic_with_error!(&env, TokenError::NoForcedTransferReceiver));
        if to != receiver {
            panic_with_error!(&env, TokenError::InvalidForcedTransferReceiver);
        }

        // req = sha256(from, to, amount, nonce, data, extra_data): binds the whole request
        // (incl. audit context) so execute cannot deviate from what was requested.
        let mut bytes = Bytes::new(&env);
        bytes.append(&from.clone().to_xdr(&env));
        bytes.append(&to.clone().to_xdr(&env));
        bytes.append(&Bytes::from_slice(&env, &amount.to_be_bytes()));
        bytes.append(&Bytes::from_slice(&env, &nonce.to_be_bytes()));
        bytes.append(&data.clone().to_xdr(&env));
        bytes.append(&extra_data.clone().to_xdr(&env));
        let req: BytesN<32> = env.crypto().sha256(&bytes).into();

        let now = env.ledger().timestamp();
        let delay = state::read_delay(&env);

        match state::read_forced_transfer_request(&env, &req) {
            None => {
                let et = now + delay;
                state::write_forced_transfer_request(&env, &req, et);
                ForcedTransferRequest {
                    from,
                    to,
                    amount,
                    nonce,
                    data,
                    extra_data,
                    et,
                }
                .publish(&env);
                false
            }
            Some(et) => {
                if et >= now {
                    panic_with_error!(&env, TokenError::TooEarlyToExecute);
                }
                state::remove_forced_transfer_request(&env, &req);
                update_balance(&env, Some(from.clone()), Some(to.clone()), amount);
                events::Transfer {
                    from: from.clone(),
                    to: to.clone(),
                    to_muxed_id: None,
                    amount,
                }
                .publish(&env);
                ForcedTransferEffected {
                    from,
                    to,
                    amount,
                    nonce,
                    data,
                    extra_data,
                }
                .publish(&env);
                true
            }
        }
    }

    pub fn revoke_forced_transfer(env: Env, caller: Address, req: BytesN<32>) {
        require_owner_or_revoker(&env, &caller);
        state::remove_forced_transfer_request(&env, &req);
        ForcedTransferRevoked { req }.publish(&env);
    }

    // set_forced_transfer_receiver: the fixed Cactus custody address forced_transfer may
    // move funds into. Governance-level timelock (its being easily changeable would let a
    // compromised owner redirect clawbacks). Two-call pattern; revoke by owner-or-revoker.
    pub fn set_forced_transfer_receiver(env: Env, new_receiver: Address) {
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        let now = env.ledger().timestamp();
        let next = state::read_next_forced_transfer_receiver(&env); // Option<Address>

        if let Some(et) = state::read_et_next_forced_transfer_receiver(&env) {
            if next.unwrap() != new_receiver {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et >= now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_forced_transfer_receiver(&env, &new_receiver);
            state::remove_et_next_forced_transfer_receiver(&env);
            state::remove_next_forced_transfer_receiver(&env);
            ForcedReceiverEffected {
                receiver: new_receiver,
            }
            .publish(&env);
            return;
        }

        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;
        state::write_next_forced_transfer_receiver(&env, &new_receiver);
        state::write_et_next_forced_transfer_receiver(&env, effective_time);

        ForcedReceiverRequest {
            next_receiver: new_receiver,
            effective_time,
        }
        .publish(&env);
    }

    pub fn revoke_forced_transfer_receiver(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_forced_transfer_receiver(&env);
        state::remove_next_forced_transfer_receiver(&env);
        ForcedReceiverRevoked {}.publish(&env);
    }

    // ---------- pause ----------

    // pause: operator, immediate, non-revocable. Pure risk contraction (emergency brake).
    pub fn pause(env: Env) {
        let operator = state::read_operator(&env);
        operator.require_auth();
        bump_instance(&env);
        state::write_paused(&env, true);
        // Void any in-flight unpause so its delay window cannot have elapsed before this
        // pause: every pause forces the unpause clock to restart from scratch. Without this,
        // an unpause request pre-staged (and matured) while unpaused could re-open the gate
        // instantly the moment operator pauses, defeating the unpause delay.
        state::remove_et_next_unpause(&env);
        Paused { operator }.publish(&env);
    }

    // unpause: owner, delay tier, two-call. Revocable by owner-or-revoker.
    // Prevents a compromised owner from re-opening the gate instantly during an incident.
    pub fn request_unpause(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();
        bump_instance(&env);

        // defense in depth: only meaningful while paused; also blocks pre-staging the unpause
        // clock while the contract is running normally.
        if !state::read_paused(&env) {
            panic_with_error!(&env, TokenError::NotPaused);
        }
        if state::read_et_next_unpause(&env).is_some() {
            panic_with_error!(&env, TokenError::PendingRequestExists);
        }
        let now = env.ledger().timestamp();
        let delay = state::read_delay(&env);
        let effective_time = now + delay;
        state::write_et_next_unpause(&env, effective_time);
        GlobalUnpauseRequest { effective_time }.publish(&env);
    }

    pub fn unpause(env: Env) {
        let owner = state::read_owner(&env);
        owner.require_auth();
        bump_instance(&env);

        let now = env.ledger().timestamp();
        match state::read_et_next_unpause(&env) {
            Some(et) if et < now => {}
            Some(_) => panic_with_error!(&env, TokenError::TooEarlyToExecute),
            None => panic_with_error!(&env, TokenError::NoPendingUnpause),
        }
        state::write_paused(&env, false);
        state::remove_et_next_unpause(&env);
        GlobalUnpauseEffected { owner }.publish(&env);
    }

    pub fn revoke_next_unpause(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_unpause(&env);
        UnpauseRevoked {}.publish(&env);
    }

    pub fn revoke_next_delay(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_delay(&env);
        state::remove_next_delay(&env);
        DelayRevoked {}.publish(&env);
    }

    // revoker guards the operator seat (adjacency rule): owner-or-revoker may revoke.
    pub fn revoke_next_operator(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_operator(&env);
        state::remove_next_operator(&env);
        OperatorRevoked {}.publish(&env);
    }

    // self-exclusion rule (#1): the revoker rotation is revoked by owner-or-operator, never revoker.
    pub fn revoke_next_revoker(env: Env, caller: Address) {
        require_owner_or_operator(&env, &caller);
        state::remove_et_next_revoker(&env);
        state::remove_next_revoker(&env);
        RevokerRevoked {}.publish(&env);
    }

    // ---------- global mintBudget management ----------
    //
    // This chain's mintBudget is allocated by Ethereum and relayed in over an off-chain
    // channel; there is no local way to conjure budget. Both entry points take the new
    // *cumulative* total rather than a per-call delta and diff it against a stored
    // watermark, so a replayed or stale submission panics instead of applying twice or
    // silently doing nothing. Amounts are in this contract's own decimals, which already
    // match the cross-chain shared decimals (9) — no scaling here.

    // the sole address authorized to call claim_mint_budget_from_eth. Must differ from the
    // operator: the submitter raises this chain's mint capacity and the operator consumes it
    // via mint_to, so one key holding both could walk the whole path alone. Governance-level
    // timelock, two-call pattern; revocable by owner-or-revoker.
    pub fn set_mint_budget_submitter(env: Env, new_submitter: Address) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        // Checked on the request call and again on the execute call, since the operator
        // may have changed inside the gov-delay window.
        check_operator_submitter_distinct(
            &env,
            &state::read_operator(&env),
            &Some(new_submitter.clone()),
        );

        let now = env.ledger().timestamp();
        let next = state::read_next_mint_budget_submitter(&env); // Option<Address>

        if let Some(et) = state::read_et_next_mint_budget_submitter(&env) {
            // next is always Some while a request is pending, no need to check
            if next.unwrap() != new_submitter {
                panic_with_error!(&env, TokenError::PendingRequestExists);
            }
            if et >= now {
                panic_with_error!(&env, TokenError::TooEarlyToExecute);
            }
            state::write_mint_budget_submitter(&env, &new_submitter);
            state::remove_et_next_mint_budget_submitter(&env);
            state::remove_next_mint_budget_submitter(&env);
            MintBudgetSubmitterEffected {
                mint_budget_submitter: new_submitter,
            }
            .publish(&env);
            return;
        }

        let gov_delay = state::read_gov_delay(&env);
        let effective_time = now + gov_delay;
        state::write_next_mint_budget_submitter(&env, &new_submitter);
        state::write_et_next_mint_budget_submitter(&env, effective_time);

        MintBudgetSubmitterRequest {
            current_mint_budget_submitter: state::read_mint_budget_submitter(&env),
            next_mint_budget_submitter: new_submitter,
            effective_time,
        }
        .publish(&env);
    }

    pub fn revoke_mint_budget_submitter(env: Env, caller: Address) {
        require_owner_or_revoker(&env, &caller);
        state::remove_et_next_mint_budget_submitter(&env);
        state::remove_next_mint_budget_submitter(&env);
        MintBudgetSubmitterRevoked {}.publish(&env);
    }

    // declares this chain's own eid; changeable only until mintBudget has moved under it
    pub fn set_local_eid(env: Env, new_local_eid: u32) {
        // onlyOwner
        let owner = state::read_owner(&env);
        owner.require_auth();

        bump_instance(&env);

        if new_local_eid == 0 {
            panic_with_error!(&env, TokenError::ZeroValue);
        }
        if new_local_eid != state::read_local_eid(&env)
            && (state::read_total_allocated_amount(&env) != 0
                || state::read_total_returned_amount(&env) != 0)
        {
            panic_with_error!(&env, TokenError::LocalEidLocked);
        }

        state::write_local_eid(&env, new_local_eid);
        SetLocalEid {
            local_eid: new_local_eid,
        }
        .publish(&env);
    }

    // credits mintBudget granted by Ethereum, by the new cumulative total's delta; mirrors
    // MTokenSide.claimMintBudgetFromEth (EVM). dst_eid is misdelivery protection, not routing:
    // a submission prepared for another side chain carries that chain's eid and fails here
    // instead of being taken for this chain's own cumulative value. Pause-gated: while paused
    // this chain's mint capacity must not keep growing.
    pub fn claim_mint_budget_from_eth(
        env: Env,
        dst_eid: u32,
        new_total_allocated_amount: i128,
        src_tx_hash: BytesN<32>,
    ) {
        // onlyMintBudgetSubmitter
        let submitter = require_mint_budget_submitter(&env);
        require_not_paused(&env);
        check_nonnegative_amount(&env, new_total_allocated_amount);

        bump_instance(&env);

        let local_eid = get_local_eid(&env);
        if dst_eid != local_eid {
            panic_with_error!(&env, TokenError::WrongTargetChain);
        }

        let delta_amount = advance_watermark(
            &env,
            state::read_total_allocated_amount(&env),
            new_total_allocated_amount,
        );
        state::write_total_allocated_amount(&env, new_total_allocated_amount);
        state::write_mint_budget(&env, state::read_mint_budget(&env) + delta_amount);

        ClaimMintBudgetFromEth {
            caller: submitter,
            dst_eid: local_eid,
            delta_amount,
            total_allocated_amount: new_total_allocated_amount,
            src_tx_hash,
        }
        .publish(&env);
    }

    // returns mintBudget to Ethereum, by the new cumulative total's delta; mirrors
    // MTokenSide.returnMintBudgetToEth (EVM). Deliberately not pause-gated: it only ever
    // shrinks this chain's mintBudget, and its upstream is a local redemption that Ethereum
    // cannot pause — blocking it would seal off the one path that lowers mint capacity.
    pub fn return_mint_budget_to_eth(env: Env, new_total_returned_amount: i128) {
        // onlyOperator
        let operator = state::read_operator(&env);
        operator.require_auth();
        check_nonnegative_amount(&env, new_total_returned_amount);

        bump_instance(&env);

        let local_eid = get_local_eid(&env);
        let delta_amount = advance_watermark(
            &env,
            state::read_total_returned_amount(&env),
            new_total_returned_amount,
        );

        let budget = state::read_mint_budget(&env);
        if delta_amount > budget {
            panic_with_error!(&env, TokenError::MintBudgetNotEnough);
        }
        state::write_total_returned_amount(&env, new_total_returned_amount);
        state::write_mint_budget(&env, budget - delta_amount);

        ReturnMintBudgetToEth {
            caller: operator,
            local_eid,
            delta_amount,
            total_returned_amount: new_total_returned_amount,
        }
        .publish(&env);
    }

    pub fn mint_to(env: Env, receiver: Address, amount: i128, nonce: u64) -> bool {
        let operator = state::read_operator(&env);
        operator.require_auth();
        require_not_paused(&env);
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
                if et >= now {
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

    pub fn revoke_mint_request(env: Env, caller: Address, req: BytesN<32>) {
        require_owner_or_revoker(&env, &caller);

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

    pub fn et_next_owner(env: Env) -> Option<u64> {
        state::read_et_next_owner(&env)
    }

    pub fn operator(env: Env) -> Address {
        state::read_operator(&env)
    }

    pub fn next_operator(env: Env) -> Option<Address> {
        state::read_next_operator(&env)
    }

    pub fn et_next_operator(env: Env) -> Option<u64> {
        state::read_et_next_operator(&env)
    }

    pub fn revoker(env: Env) -> Address {
        state::read_revoker(&env)
    }

    pub fn next_revoker(env: Env) -> Option<Address> {
        state::read_next_revoker(&env)
    }

    pub fn et_next_revoker(env: Env) -> Option<u64> {
        state::read_et_next_revoker(&env)
    }

    pub fn delay(env: Env) -> u64 {
        state::read_delay(&env)
    }

    pub fn next_delay(env: Env) -> Option<u64> {
        state::read_next_delay(&env)
    }

    pub fn et_next_delay(env: Env) -> Option<u64> {
        state::read_et_next_delay(&env)
    }

    pub fn gov_delay(env: Env) -> u64 {
        state::read_gov_delay(&env)
    }

    pub fn next_gov_delay(env: Env) -> Option<u64> {
        state::read_next_gov_delay(&env)
    }

    pub fn et_next_gov_delay(env: Env) -> Option<u64> {
        state::read_et_next_gov_delay(&env)
    }

    pub fn next_upgrade_wasm_hash(env: Env) -> Option<BytesN<32>> {
        state::read_next_upgrade_wasm_hash(&env)
    }

    pub fn et_next_upgrade(env: Env) -> Option<u64> {
        state::read_et_next_upgrade(&env)
    }

    pub fn mint_budget(env: Env) -> i128 {
        state::read_mint_budget(&env)
    }

    pub fn mint_budget_submitter(env: Env) -> Option<Address> {
        state::read_mint_budget_submitter(&env)
    }

    pub fn next_mint_budget_submitter(env: Env) -> Option<Address> {
        state::read_next_mint_budget_submitter(&env)
    }

    pub fn et_next_mint_budget_submitter(env: Env) -> Option<u64> {
        state::read_et_next_mint_budget_submitter(&env)
    }

    // this chain's own eid, 0 until set_local_eid has run
    pub fn local_eid(env: Env) -> u32 {
        state::read_local_eid(&env)
    }

    // cumulative amount granted by Ethereum and claimed via claim_mint_budget_from_eth
    // (never decreases)
    pub fn total_allocated_amount(env: Env) -> i128 {
        state::read_total_allocated_amount(&env)
    }

    // cumulative amount returned to Ethereum via return_mint_budget_to_eth (never decreases)
    pub fn total_returned_amount(env: Env) -> i128 {
        state::read_total_returned_amount(&env)
    }

    pub fn mint_request_et(env: Env, req: BytesN<32>) -> Option<u64> {
        state::read_mint_request(&env, &req)
    }

    pub fn is_blocked(env: Env, user: Address) -> bool {
        state::is_blocked(&env, &user)
    }

    pub fn total_supply(env: Env) -> i128 {
        state::read_total_supply(&env)
    }

    pub fn paused(env: Env) -> bool {
        state::read_paused(&env)
    }

    pub fn et_next_unpause(env: Env) -> Option<u64> {
        state::read_et_next_unpause(&env)
    }

    pub fn forced_transfer_receiver(env: Env) -> Option<Address> {
        state::read_forced_transfer_receiver(&env)
    }

    pub fn next_forced_transfer_receiver(env: Env) -> Option<Address> {
        state::read_next_forced_transfer_receiver(&env)
    }

    pub fn et_next_forced_transfer_receiver(env: Env) -> Option<u64> {
        state::read_et_next_forced_transfer_receiver(&env)
    }

    pub fn forced_transfer_request_et(env: Env, req: BytesN<32>) -> Option<u64> {
        state::read_forced_transfer_request(&env, &req)
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
        require_not_paused(&env);
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
        require_not_paused(&env);
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
        require_not_paused(&env);
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

// mirrors MTokenSide.ClaimMintBudgetFromEth (EVM): delta_amount is what this call credited
// and total_allocated_amount the cumulative total after it — both readable off a single event
// so off-chain reconciliation never has to replay history. caller and dst_eid are topics so a
// third party can filter by chain id, as required by the PRD.
#[contractevent]
pub struct ClaimMintBudgetFromEth {
    #[topic]
    pub caller: Address,
    // always this chain's own eid; carried so the two ends reconcile field for field
    #[topic]
    pub dst_eid: u32,
    pub delta_amount: i128,
    pub total_allocated_amount: i128,
    // the Ethereum tx hash, recorded as given; the contract does not verify it. BytesN<32>
    // makes the length part of the ABI, like bytes32 on the EVM side
    pub src_tx_hash: BytesN<32>,
}

// mirrors MTokenSide.ReturnMintBudgetToEth (EVM)
#[contractevent]
pub struct ReturnMintBudgetToEth {
    #[topic]
    pub caller: Address,
    #[topic]
    pub local_eid: u32,
    pub delta_amount: i128,
    pub total_returned_amount: i128,
}

#[contractevent]
pub struct SetLocalEid {
    pub local_eid: u32,
}

#[contractevent]
pub struct MintBudgetSubmitterRequest {
    pub current_mint_budget_submitter: Option<Address>,
    pub next_mint_budget_submitter: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct MintBudgetSubmitterEffected {
    pub mint_budget_submitter: Address,
}

#[contractevent]
pub struct MintBudgetSubmitterRevoked {}

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
pub struct ForcedTransferRequest {
    #[topic]
    pub from: Address,
    #[topic]
    pub to: Address,
    pub amount: i128,
    pub nonce: u64,
    pub data: String,
    pub extra_data: String,
    pub et: u64,
}

#[contractevent]
pub struct ForcedTransferEffected {
    #[topic]
    pub from: Address,
    #[topic]
    pub to: Address,
    pub amount: i128,
    pub nonce: u64,
    pub data: String,
    pub extra_data: String,
}

#[contractevent]
pub struct ForcedTransferRevoked {
    pub req: BytesN<32>,
}

#[contractevent]
pub struct ForcedReceiverRequest {
    pub next_receiver: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct ForcedReceiverEffected {
    pub receiver: Address,
}

#[contractevent]
pub struct ForcedReceiverRevoked {}

#[contractevent]
pub struct Paused {
    pub operator: Address,
}

#[contractevent]
pub struct GlobalUnpauseEffected {
    pub owner: Address,
}

#[contractevent]
pub struct GlobalUnpauseRequest {
    pub effective_time: u64,
}

#[contractevent]
pub struct UnpauseRevoked {}

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
    pub caller: Address,
    // Real pending hash for a valid revoke; all-zero sentinel when nothing was pending.
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

fn require_not_paused(env: &Env) {
    if state::read_paused(env) {
        panic_with_error!(env, TokenError::ContractPaused);
    }
}

// Revocation is widened to "owner OR revoker": owner is the superior role and may
// recall a pending delayed op. Soroban has no "either-of" auth primitive, so the
// caller is passed explicitly and checked for membership.
fn require_owner_or_revoker(env: &Env, caller: &Address) {
    caller.require_auth();
    if *caller != state::read_owner(env) && *caller != state::read_revoker(env) {
        panic_with_error!(env, TokenError::Unauthorized);
    }
}

// setRevoker rotation is revoked by owner OR operator (self-exclusion rule: never the revoker).
fn require_owner_or_operator(env: &Env, caller: &Address) {
    caller.require_auth();
    if *caller != state::read_owner(env) && *caller != state::read_operator(env) {
        panic_with_error!(env, TokenError::Unauthorized);
    }
}

// the submitter credits mintBudget and the operator spends it, so one key holding both roles
// could walk credit -> mint alone; both setters enforce the split, on each call.
fn check_operator_submitter_distinct(env: &Env, operator: &Address, submitter: &Option<Address>) {
    if submitter.as_ref() == Some(operator) {
        panic_with_error!(env, TokenError::OperatorSubmitterConflict);
    }
}

fn require_mint_budget_submitter(env: &Env) -> Address {
    let submitter = state::read_mint_budget_submitter(env)
        .unwrap_or_else(|| panic_with_error!(env, TokenError::NotMintBudgetSubmitter));
    submitter.require_auth();
    submitter
}

// reads this chain's own eid, panicking if it has not been set yet
fn get_local_eid(env: &Env) -> u32 {
    let local_eid = state::read_local_eid(env);
    if local_eid == 0 {
        panic_with_error!(env, TokenError::LocalEidNotSet);
    }
    local_eid
}

// monotonic advance of one cumulative watermark, shared by both mintBudget entry points: a
// submission must state a total strictly above the recorded one, so a replayed or stale value
// panics rather than silently landing as a no-op (PRD §4.4).
fn advance_watermark(env: &Env, curr: i128, new_total: i128) -> i128 {
    if new_total > MAX_MINT_BUDGET_RELAY_AMOUNT {
        panic_with_error!(env, TokenError::MintBudgetAmountTooLarge);
    }
    if curr >= new_total {
        panic_with_error!(env, TokenError::StaleMintBudgetSubmission);
    }
    new_total - curr
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
