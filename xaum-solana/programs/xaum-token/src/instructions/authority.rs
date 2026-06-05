use anchor_lang::prelude::*;

use super::super::mtoken::xaum::{MAX_ACCEPTABLE_DELAY, MIN_ACCEPTABLE_DELAY};
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

#[derive(Accounts)]
pub struct RevokerOp<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = revoker @ ErrorCode::NotRevoker,
    )]
    state: Account<'info, State>,
    revoker: Signer<'info>,
}

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

pub fn revoke_next_owner(ctx: Context<OwnerOp>) -> Result<()> {
    ctx.accounts.state.next_owner_et = 0;
    emit!(RevokeNextOwner {
        pending_owner: ctx.accounts.state.next_owner,
    });
    Ok(())
}

//================================================================================

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

pub fn revoke_next_operator(ctx: Context<RevokerOp>) -> Result<()> {
    ctx.accounts.state.next_operator_et = 0;
    emit!(RevokeNextOperator {
        pending_operator: ctx.accounts.state.next_operator,
    });
    Ok(())
}

//================================================================================

pub fn set_revoker(ctx: Context<OwnerOp>, new_revoker: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_revoker_et == 0 {
        state.next_revoker = new_revoker;
        state.next_revoker_et = clock.unix_timestamp + state.delay;
        emit!(SetRevokerRequest {
            old_revoker: state.revoker,
            new_revoker,
            et: state.next_revoker_et,
        });
    } else {
        require!(
            state.next_revoker_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(
            state.next_revoker == new_revoker,
            ErrorCode::RequestMismatch
        );
        state.revoker = state.next_revoker;
        state.next_revoker_et = 0;
        emit!(SetRevokerEffected { new_revoker });
    }
    Ok(())
}

pub fn revoke_next_revoker(ctx: Context<OwnerOp>) -> Result<()> {
    ctx.accounts.state.next_revoker_et = 0;
    emit!(RevokeNextRevoker {
        pending_revoker: ctx.accounts.state.next_revoker,
    });
    Ok(())
}

//================================================================================

pub fn set_messager(ctx: Context<OwnerOp>, new_messager: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_messager_et == 0 {
        state.next_messager = new_messager;
        state.next_messager_et = clock.unix_timestamp + state.delay;
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

pub fn revoke_next_messager(ctx: Context<RevokerOp>) -> Result<()> {
    ctx.accounts.state.next_messager_et = 0;
    emit!(RevokeNextMessager {
        pending_messager: ctx.accounts.state.next_messager,
    });
    Ok(())
}

//================================================================================

pub fn set_delay(ctx: Context<OwnerOp>, new_delay: i64) -> Result<()> {
    require!(
        new_delay >= MIN_ACCEPTABLE_DELAY,
        ErrorCode::DelayBelowMinimum
    );
    require!(
        new_delay <= MAX_ACCEPTABLE_DELAY,
        ErrorCode::DelayExceedsMaximum
    );

    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_delay_et == 0 {
        state.next_delay = new_delay;
        state.next_delay_et = clock.unix_timestamp + state.delay;
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
        state.delay = state.next_delay;
        state.next_delay_et = 0;
        emit!(SetDelayEffected { new_delay });
    }
    Ok(())
}

pub fn revoke_next_delay(ctx: Context<RevokerOp>) -> Result<()> {
    ctx.accounts.state.next_delay_et = 0;
    emit!(RevokeNextDelay {
        pending_delay: ctx.accounts.state.next_delay,
    });
    Ok(())
}

//================================================================================

// gov_delay is the timelock for ownership transfer only (1h–7d).
// Changes to gov_delay are themselves timelocked by the current gov_delay value,
// mirroring the EVM setGovDelay pattern in Ownable2StepTimeLockUpgradeable.
pub fn set_gov_delay(ctx: Context<OwnerOp>, new_delay: i64) -> Result<()> {
    require!(
        new_delay >= MIN_ACCEPTABLE_DELAY,
        ErrorCode::DelayBelowMinimum
    );
    require!(
        new_delay <= MAX_ACCEPTABLE_DELAY,
        ErrorCode::DelayExceedsMaximum
    );

    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_gov_delay_et == 0 {
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
        state.gov_delay = state.next_gov_delay;
        state.next_gov_delay_et = 0;
        emit!(SetGovDelayEffected { new_delay });
    }
    Ok(())
}

// Only owner can revoke a pending gov_delay change (mirrors EVM revokeNextGovDelay onlyOwner).
pub fn revoke_next_gov_delay(ctx: Context<OwnerOp>) -> Result<()> {
    ctx.accounts.state.next_gov_delay_et = 0;
    emit!(RevokeNextGovDelay {
        pending_gov_delay: ctx.accounts.state.next_gov_delay,
    });
    Ok(())
}

//================================================================================

pub fn revoke_mint(ctx: Context<RevokerOp>) -> Result<()> {
    ctx.accounts.state.next_mint_et = 0;
    emit!(RevokeNextMint {
        pending_mint_nonce: ctx.accounts.state.next_mint_nonce,
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
