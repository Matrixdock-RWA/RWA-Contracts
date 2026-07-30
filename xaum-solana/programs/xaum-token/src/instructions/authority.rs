use anchor_lang::prelude::*;

use super::super::mtoken::xaum::{MAX_DELAY, MAX_GOV_DELAY, MIN_DELAY, MIN_GOV_DELAY};
use super::super::mtoken::{errors::ErrorCode, events::*, state::State};

#[derive(Accounts)]
pub struct OwnerOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner @ ErrorCode::NotOwner,
    )]
    state: Account<'info, State>,
    owner: Signer<'info>,
}

// Signed by the pending owner (next_owner) to accept a timelocked ownership transfer.
#[derive(Accounts)]
pub struct AcceptOwnerOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = next_owner @ ErrorCode::NotNextOwner,
    )]
    state: Account<'info, State>,
    next_owner: Signer<'info>,
}

// Signed by the pending revoker (next_revoker) to accept a timelocked setRevoker (#1).
#[derive(Accounts)]
pub struct AcceptRevokerOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = next_revoker @ ErrorCode::NotNextRevoker,
    )]
    state: Account<'info, State>,
    next_revoker: Signer<'info>,
}

#[derive(Accounts)]
pub struct OperatorOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,
    operator: Signer<'info>,
}

// Revocation context: signer must be owner OR revoker (checked in-handler).
// Anchor `has_one` cannot express an OR, so the check is manual.
#[derive(Accounts)]
pub struct OwnerOrRevokerOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
    )]
    state: Account<'info, State>,
    signer: Signer<'info>,
}

// Revocation context for setRevoker (#1): signer must be owner OR operator
// (self-exclusion — the revoker cannot cancel its own replacement).
#[derive(Accounts)]
pub struct OwnerOrOperatorOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
    )]
    state: Account<'info, State>,
    signer: Signer<'info>,
}

fn require_owner_or_revoker(state: &State, signer: &Pubkey) -> Result<()> {
    require!(
        *signer == state.owner || *signer == state.revoker,
        ErrorCode::NotOwnerOrRevoker
    );
    Ok(())
}

fn require_owner_or_operator(state: &State, signer: &Pubkey) -> Result<()> {
    require!(
        *signer == state.owner || *signer == state.operator,
        ErrorCode::NotOwnerOrOperator
    );
    Ok(())
}

//================================================================================
// #2 TransferOwnership — gov_delay, two-step accept, revoke by owner/revoker.

// Step 1 (owner): start a timelocked ownership transfer. The transfer only takes
// effect once the designated new owner calls accept_ownership after gov_delay has
// elapsed, mirroring the EVM Ownable2StepTimeLock pattern. A pending transfer must be
// revoked before a new one can be started.
pub fn transfer_ownership(ctx: Context<OwnerOp>, new_owner: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require!(state.next_owner_et == 0, ErrorCode::PendingOwnerExist);
    let clock = Clock::get()?;
    state.next_owner = new_owner;
    state.next_owner_et = clock.unix_timestamp + state.gov_delay;
    emit!(SetOwnerRequest {
        old_owner: state.owner,
        new_owner,
        et: state.next_owner_et,
    });
    Ok(())
}

// Step 2 (new owner): accept the pending ownership transfer once gov_delay has elapsed.
// Only the pending owner (next_owner) can sign, enforced by AcceptOwnerOp's has_one.
pub fn accept_ownership(ctx: Context<AcceptOwnerOp>) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require!(state.next_owner_et != 0, ErrorCode::NoPendingOwner);
    let clock = Clock::get()?;
    require!(
        state.next_owner_et <= clock.unix_timestamp,
        ErrorCode::NotEffective
    );
    state.owner = state.next_owner;
    state.next_owner_et = 0;
    emit!(SetOwnerEffected {
        new_owner: state.owner,
    });
    Ok(())
}

pub fn revoke_next_owner(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_owner_et = 0;
    emit!(RevokeNextOwner {
        pending_owner: state.next_owner,
    });
    Ok(())
}

//================================================================================
// #12 setOperator — delay, revoke by owner/revoker.

pub fn set_operator(ctx: Context<OwnerOp>, new_operator: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_operator_et == 0 {
        state.next_operator = new_operator;
        state.next_operator_et = clock.unix_timestamp + state.delay;
        emit!(SetOperatorRequest {
            old_operator: state.operator,
            new_operator,
            et: state.next_operator_et,
        });
    } else {
        require!(
            state.next_operator_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(
            state.next_operator == new_operator,
            ErrorCode::RequestMismatch
        );
        state.operator = state.next_operator;
        state.next_operator_et = 0;
        emit!(SetOperatorEffected { new_operator });
    }
    Ok(())
}

pub fn revoke_next_operator(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_operator_et = 0;
    emit!(RevokeNextOperator {
        pending_operator: state.next_operator,
    });
    Ok(())
}

//================================================================================
// #1 setRevoker — gov_delay, two-step accept, revoke by owner/operator (self-exclusion).

// Step 1 (owner): record the pending revoker. A pending change must be revoked before
// a new one can start. Effected only when the new revoker calls accept_revoker.
pub fn set_revoker(ctx: Context<OwnerOp>, new_revoker: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require!(state.next_revoker_et == 0, ErrorCode::PendingRevokerExist);
    let clock = Clock::get()?;
    state.next_revoker = new_revoker;
    state.next_revoker_et = clock.unix_timestamp + state.gov_delay;
    emit!(SetRevokerRequest {
        old_revoker: state.revoker,
        new_revoker,
        et: state.next_revoker_et,
    });
    Ok(())
}

// Step 2 (new revoker): accept the pending revoker change once gov_delay has elapsed
// (guards against setting a wrong/dead address).
pub fn accept_revoker(ctx: Context<AcceptRevokerOp>) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require!(state.next_revoker_et != 0, ErrorCode::NoPendingRevoker);
    let clock = Clock::get()?;
    require!(
        state.next_revoker_et <= clock.unix_timestamp,
        ErrorCode::NotEffective
    );
    state.revoker = state.next_revoker;
    state.next_revoker_et = 0;
    emit!(SetRevokerEffected {
        new_revoker: state.revoker,
    });
    Ok(())
}

pub fn revoke_next_revoker(ctx: Context<OwnerOrOperatorOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_operator(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_revoker_et = 0;
    emit!(RevokeNextRevoker {
        pending_revoker: state.next_revoker,
    });
    Ok(())
}

//================================================================================
// #6 setMessager — gov_delay, revoke by owner/revoker.

pub fn set_messager(ctx: Context<OwnerOp>, new_messager: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_messager_et == 0 {
        state.next_messager = new_messager;
        state.next_messager_et = clock.unix_timestamp + state.gov_delay;
        emit!(SetMessagerRequest {
            old_messager: state.messager,
            new_messager,
            et: state.next_messager_et,
        });
    } else {
        require!(
            state.next_messager_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(
            state.next_messager == new_messager,
            ErrorCode::RequestMismatch
        );
        state.messager = state.next_messager;
        state.next_messager_et = 0;
        emit!(SetMessagerEffected { new_messager });
    }
    Ok(())
}

pub fn revoke_next_messager(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_messager_et = 0;
    emit!(RevokeNextMessager {
        pending_messager: state.next_messager,
    });
    Ok(())
}

//================================================================================
// #4 setDelay — operational delay (1h–48h), PROTECTED BY gov_delay; enforces
// new_delay <= gov_delay (tiering: prevents shortening delay then acting quickly).

pub fn set_delay(ctx: Context<OwnerOp>, new_delay: i64) -> Result<()> {
    require!(new_delay >= MIN_DELAY, ErrorCode::DelayBelowMinimum);
    require!(new_delay <= MAX_DELAY, ErrorCode::DelayExceedsMaximum);

    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_delay_et == 0 {
        require!(
            new_delay <= state.gov_delay,
            ErrorCode::DelayExceedsGovDelay
        );
        state.next_delay = new_delay;
        state.next_delay_et = clock.unix_timestamp + state.gov_delay;
        emit!(SetDelayRequest {
            old_delay: state.delay,
            new_delay,
            et: state.next_delay_et,
        });
    } else {
        require!(
            state.next_delay_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(state.next_delay == new_delay, ErrorCode::RequestMismatch);
        require!(
            new_delay <= state.gov_delay,
            ErrorCode::DelayExceedsGovDelay
        );
        state.delay = state.next_delay;
        state.next_delay_et = 0;
        emit!(SetDelayEffected { new_delay });
    }
    Ok(())
}

pub fn revoke_next_delay(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_delay_et = 0;
    emit!(RevokeNextDelay {
        pending_delay: state.next_delay,
    });
    Ok(())
}

//================================================================================
// #3 setGovDelay — governance delay (24h–7d), self-protected by the CURRENT gov_delay;
// enforces new_gov_delay >= delay (invariant gov_delay >= delay).

pub fn set_gov_delay(ctx: Context<OwnerOp>, new_delay: i64) -> Result<()> {
    require!(new_delay >= MIN_GOV_DELAY, ErrorCode::DelayBelowMinimum);
    require!(new_delay <= MAX_GOV_DELAY, ErrorCode::DelayExceedsMaximum);

    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_gov_delay_et == 0 {
        require!(new_delay >= state.delay, ErrorCode::GovDelayBelowDelay);
        let curr_gov_delay = state.gov_delay;
        state.next_gov_delay = new_delay;
        state.next_gov_delay_et = clock.unix_timestamp + curr_gov_delay;
        emit!(SetGovDelayRequest {
            old_delay: curr_gov_delay,
            new_delay,
            et: state.next_gov_delay_et,
        });
    } else {
        require!(
            state.next_gov_delay_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(
            state.next_gov_delay == new_delay,
            ErrorCode::RequestMismatch
        );
        require!(new_delay >= state.delay, ErrorCode::GovDelayBelowDelay);
        state.gov_delay = state.next_gov_delay;
        state.next_gov_delay_et = 0;
        emit!(SetGovDelayEffected { new_delay });
    }
    Ok(())
}

pub fn revoke_next_gov_delay(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_gov_delay_et = 0;
    emit!(RevokeNextGovDelay {
        pending_gov_delay: state.next_gov_delay,
    });
    Ok(())
}

//================================================================================
// #19 mintTo revoke — revoke by owner/revoker.

pub fn revoke_mint(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_mint_et = 0;
    emit!(RevokeNextMint {
        pending_mint_nonce: state.next_mint_nonce,
    });
    Ok(())
}

pub fn change_mint_budget(ctx: Context<OperatorOp>, delta: i64) -> Result<()> {
    let state = &mut ctx.accounts.state;

    if delta > 0 {
        state.mint_budget += delta as u64;
    } else {
        require!(
            state.mint_budget >= -delta as u64,
            ErrorCode::MintBudgetNotEnough
        );
        state.mint_budget -= -delta as u64;
    }
    emit!(ChangeMintBudget { delta });

    Ok(())
}

//================================================================================
// #11 setForcedTransferReceiver — gov_delay, revoke by owner/revoker.

pub fn set_forced_transfer_receiver(ctx: Context<OwnerOp>, new_receiver: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_forced_transfer_receiver_et == 0 {
        state.next_forced_transfer_receiver = new_receiver;
        state.next_forced_transfer_receiver_et = clock.unix_timestamp + state.gov_delay;
        emit!(SetForcedTransferReceiverRequest {
            old_receiver: state.forced_transfer_receiver,
            new_receiver,
            et: state.next_forced_transfer_receiver_et,
        });
    } else {
        require!(
            state.next_forced_transfer_receiver_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(
            state.next_forced_transfer_receiver == new_receiver,
            ErrorCode::RequestMismatch
        );
        state.forced_transfer_receiver = state.next_forced_transfer_receiver;
        state.next_forced_transfer_receiver_et = 0;
        emit!(SetForcedTransferReceiverEffected { new_receiver });
    }
    Ok(())
}

pub fn revoke_next_forced_transfer_receiver(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    state.next_forced_transfer_receiver_et = 0;
    emit!(RevokeNextForcedTransferReceiver {
        pending_receiver: state.next_forced_transfer_receiver,
    });
    Ok(())
}

// #13 forceTransfer revoke — revoke by owner/revoker.
pub fn revoke_forced_transfer(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    let hash = state.next_forced_transfer_hash;
    state.next_forced_transfer_et = 0;
    state.next_forced_transfer_hash = [0; 32];
    emit!(RevokeForcedTransfer { hash });
    Ok(())
}

// #14 GlobalUnpause revoke — revoke by owner/revoker.
pub fn revoke_unpause(ctx: Context<OwnerOrRevokerOp>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    require_owner_or_revoker(&ctx.accounts.state, &signer)?;
    let state = &mut ctx.accounts.state;
    let pending_et = state.next_unpause_et;
    state.next_unpause_et = 0;
    emit!(RevokeNextUnpause { pending_et });
    Ok(())
}
