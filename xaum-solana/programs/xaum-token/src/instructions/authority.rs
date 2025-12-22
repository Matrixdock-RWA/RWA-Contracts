// In this example the same PDA is used as both the address of the mint account and the mint authority
// This is to demonstrate that the same PDA can be used for both the address of an account and CPI signing
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

pub fn transfer_ownership(ctx: Context<OwnerOp>, new_owner: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;
    if state.next_owner_et == 0 {
        state.next_owner = new_owner;
        state.next_owner_et = clock.unix_timestamp + state.delay;
        emit!(SetOwnerRequest {
            old_owner: state.owner,
            new_owner,
            et: state.next_owner_et,
        });
    } else {
        require!(
            state.next_owner_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        require!(state.next_owner == new_owner, ErrorCode::RequestMismatch);
        state.owner = state.next_owner;
        state.next_owner_et = 0;
        emit!(SetOwnerEffected { new_owner });
    }
    Ok(())
}

pub fn revoke_next_owner(ctx: Context<OwnerOp>) -> Result<()> {
    ctx.accounts.state.next_owner_et = 0;
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
    let state = &mut ctx.accounts.state;
    state.next_delay_et = 0;
    Ok(())
}

//================================================================================

pub fn revoke_mint(ctx: Context<RevokerOp>) -> Result<()> {
    ctx.accounts.state.next_mint_et = 0;
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
