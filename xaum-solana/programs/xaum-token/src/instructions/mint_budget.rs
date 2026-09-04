use {
    anchor_lang::prelude::*,
    anchor_spl::token_interface::Mint,
    spl_token_2022::extension::{
        pausable::PausableConfig, BaseStateWithExtensions, StateWithExtensions,
    },
};

use super::super::mtoken::{errors::ErrorCode, events::*, state::State};

// XAUM_DECIMALS is fixed at 9, equal to the protocol's shared decimals, so
// relay amounts are applied directly without EVM's local/shared conversion.

#[derive(Accounts)]
pub struct ClaimMintBudget<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = mint_budget_submitter @ ErrorCode::NotMintBudgetSubmitter,
    )]
    state: Account<'info, State>,
    mint_budget_submitter: Signer<'info>,
    #[account(seeds = [b"mint"], bump)]
    mint_account: InterfaceAccount<'info, Mint>,
}

#[derive(Accounts)]
pub struct ReturnMintBudget<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,
    operator: Signer<'info>,
}

pub fn claim_mint_budget_from_eth(
    ctx: Context<ClaimMintBudget>,
    dst_eid: u32,
    new_total_allocated_amount: u64,
    // Budget can only be allocated from Ethereum, whose tx hashes are
    // keccak256, so the width is pinned by the type rather than a runtime check.
    src_tx_hash: [u8; 32],
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require_not_paused(&ctx.accounts.mint_account)?;
    let local_eid = require_local_eid(state)?;
    require!(dst_eid == local_eid, ErrorCode::WrongTargetChain);
    require!(
        new_total_allocated_amount > state.mint_budget_total_allocated_amount,
        ErrorCode::StaleMintBudgetSubmission
    );

    let delta_amount = new_total_allocated_amount - state.mint_budget_total_allocated_amount;
    state.mint_budget += delta_amount;
    state.mint_budget_total_allocated_amount = new_total_allocated_amount;

    emit!(ClaimMintBudgetFromEth {
        caller: ctx.accounts.mint_budget_submitter.key(),
        dst_eid: local_eid,
        delta_amount,
        total_allocated_amount: new_total_allocated_amount,
        src_tx_hash,
    });
    Ok(())
}

pub fn return_mint_budget_to_eth(
    ctx: Context<ReturnMintBudget>,
    new_total_returned_amount: u64,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let local_eid = require_local_eid(state)?;
    require!(
        new_total_returned_amount > state.mint_budget_total_returned_amount,
        ErrorCode::StaleMintBudgetSubmission
    );
    let delta_amount = new_total_returned_amount - state.mint_budget_total_returned_amount;
    require!(
        state.mint_budget >= delta_amount,
        ErrorCode::MintBudgetNotEnough
    );
    state.mint_budget -= delta_amount;
    state.mint_budget_total_returned_amount = new_total_returned_amount;

    emit!(ReturnMintBudgetToEth {
        caller: ctx.accounts.operator.key(),
        local_eid,
        delta_amount,
        total_returned_amount: new_total_returned_amount,
    });
    Ok(())
}

fn require_local_eid(state: &State) -> Result<u32> {
    require!(state.local_eid != 0, ErrorCode::LocalEidNotSet);
    Ok(state.local_eid)
}

fn require_not_paused(mint_account: &InterfaceAccount<Mint>) -> Result<()> {
    let mint_info = mint_account.to_account_info();
    let mint_data = mint_info.try_borrow_data()?;
    let mint_state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&mint_data)?;
    let pausable = mint_state.get_extension::<PausableConfig>()?;
    require!(!bool::from(pausable.paused), ErrorCode::Paused);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instruction::ClaimMintBudgetFromEth as Args;

    const DST_EID: u32 = 30168;
    const TOTAL: u64 = 5000;
    const HASH: [u8; 32] = [0xab; 32];

    // Wire shape of the args before `src_tx_hash` was pinned to `[u8; 32]`.
    #[derive(AnchorSerialize)]
    struct LegacyVecArgs {
        dst_eid: u32,
        new_total_allocated_amount: u64,
        src_tx_hash: Vec<u8>,
    }

    fn legacy_bytes(hash: &[u8]) -> Vec<u8> {
        LegacyVecArgs {
            dst_eid: DST_EID,
            new_total_allocated_amount: TOTAL,
            src_tx_hash: hash.to_vec(),
        }
        .try_to_vec()
        .unwrap()
    }

    fn current_bytes() -> Vec<u8> {
        Args {
            dst_eid: DST_EID,
            new_total_allocated_amount: TOTAL,
            src_tx_hash: HASH,
        }
        .try_to_vec()
        .unwrap()
    }

    // The fixed array drops the 4-byte Borsh length prefix, so a 32-byte hash
    // is 32 bytes on the wire, not 36.
    #[test]
    fn src_tx_hash_is_encoded_without_length_prefix() {
        let cur = current_bytes();
        assert_eq!(cur.len(), 4 + 8 + 32);
        assert_eq!(&cur[12..], &HASH[..]);
        assert_eq!(legacy_bytes(&HASH).len(), 4 + 8 + 4 + 32);
    }

    // Borsh does not reject trailing bytes and Anchor does not check for them,
    // so a relayer still sending the old Vec encoding is NOT rejected on-chain:
    // the length prefix is silently read as the first four hash bytes and the
    // recorded hash is corrupted. The relayer and generated IDL must therefore
    // switch to the array encoding in the same cutover as the program.
    #[test]
    fn legacy_vec_encoding_is_misparsed_not_rejected() {
        let legacy = legacy_bytes(&HASH);
        let parsed = Args::deserialize(&mut &legacy[..]).unwrap();
        assert_eq!(parsed.dst_eid, DST_EID);
        assert_eq!(parsed.new_total_allocated_amount, TOTAL);
        assert_ne!(parsed.src_tx_hash, HASH);
        assert_eq!(&parsed.src_tx_hash[..4], &32u32.to_le_bytes());
        assert_eq!(&parsed.src_tx_hash[4..], &HASH[..28]);
    }

    // Under the old encoding a short hash was caught by a runtime length check;
    // now the type makes it unrepresentable and a short payload fails to parse.
    #[test]
    fn short_payload_fails_to_deserialize() {
        let mut cur = current_bytes();
        cur.pop();
        assert!(Args::deserialize(&mut &cur[..]).is_err());
    }
}
