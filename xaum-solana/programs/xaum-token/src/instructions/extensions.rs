use anchor_lang::prelude::*;

use anchor_spl::token_interface::{
    token_metadata_update_field, transfer_fee_set, Mint, Token2022, TokenMetadataUpdateField,
    TransferFeeSetTransferFee,
};
use spl_token_2022::extension::pausable::instruction::{pause as pause_instr, resume};
use spl_token_2022::extension::pausable::PausableConfig;
use spl_token_2022::extension::{BaseStateWithExtensions, StateWithExtensions};
use spl_token_metadata_interface::state::Field;

use super::super::mtoken::events::{Paused, RevokeNextUnpause, UnpauseRequest, Unpaused};
use super::super::mtoken::utils::update_account_lamports_to_minimum_rent_balance;
use super::super::mtoken::{errors::ErrorCode, state::State};

#[derive(Accounts)]
pub struct UpdateExtension<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner @ ErrorCode::NotOwner,
    )]
    state: Account<'info, State>,

    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Pause<'info> {
    #[account(mut)]
    pub operator: Signer<'info>,

    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,

    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

// #14 GlobalUnpause is a delayed two-call op (state must be mut to record the pending et),
// so it has its own context distinct from the immediate metadata/fee updates.
#[derive(Accounts)]
pub struct Unpause<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner @ ErrorCode::NotOwner,
    )]
    state: Account<'info, State>,

    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    pub token_program: Program<'info, Token2022>,
}

pub fn update_metadata(ctx: Context<UpdateExtension>, new_uri: String) -> Result<()> {
    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    let cpi_accounts = TokenMetadataUpdateField {
        program_id: ctx.accounts.token_program.to_account_info(),
        metadata: ctx.accounts.mint_account.to_account_info(), // metadata account is the mint, since data is stored in mint
        update_authority: ctx.accounts.mint_account.to_account_info(),
    };
    let cpi_ctx = CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts)
        .with_signer(signer_seeds);
    token_metadata_update_field(cpi_ctx, Field::Uri, new_uri)?;

    ctx.accounts.mint_account.reload()?;

    update_account_lamports_to_minimum_rent_balance(
        ctx.accounts.mint_account.to_account_info(),
        ctx.accounts.owner.to_account_info(),
        ctx.accounts.system_program.to_account_info(),
    )?;

    Ok(())
}

pub fn update_transfer_fee(
    ctx: Context<UpdateExtension>,
    transfer_fee_basis_points: u16,
    maximum_fee: u64,
) -> Result<()> {
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    transfer_fee_set(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferFeeSetTransferFee {
                token_program_id: ctx.accounts.token_program.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
        transfer_fee_basis_points,
        maximum_fee,
    )
}

// Pause minting, burning, and transferring.
// Callable by operator only; takes effect immediately with no timelock (emergency safety brake).
pub fn pause(ctx: Context<Pause>) -> Result<()> {
    // A pause invalidates any pending unpause, so every pause is protected by a
    // full fresh delay — a matured request from an earlier pause can't bypass it.
    let state = &mut ctx.accounts.state;
    if state.next_unpause_et != 0 {
        let pending_et = state.next_unpause_et;
        state.next_unpause_et = 0;
        emit!(RevokeNextUnpause { pending_et });
    }

    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    let instruction = pause_instr(
        &ctx.accounts.token_program.key(),
        &ctx.accounts.mint_account.key(),
        &ctx.accounts.mint_account.key(),    // authority
        &[&ctx.accounts.mint_account.key()], // signers
    )?;

    anchor_lang::solana_program::program::invoke_signed(
        &instruction,
        &[ctx.accounts.mint_account.to_account_info()],
        signer_seeds,
    )?;

    emit!(Paused {
        caller: ctx.accounts.operator.key()
    });
    Ok(())
}

// Resume minting, burning, and transferring — #14 GlobalUnpause.
// Owner-only, delayed two-call pattern (mirrors mint_token):
//   Call 1 (et == 0): require mint currently paused, record pending unpause at
//                     now + delay, emit UnpauseRequest, return.
//   Call 2 (et != 0): verify delay elapsed, resume, emit Unpaused.
// Revocable via revoke_unpause (owner/revoker) before it takes effect; a new
// pause also clears the pending request, so a request is always bound to the
// pause it was created under.
pub fn unpause(ctx: Context<Unpause>) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;

    // Call 1: create request. Only allowed while the mint is actually paused —
    // otherwise the owner could pre-stage a matured unpause during normal
    // operation and bypass the delay of a future emergency pause.
    if state.next_unpause_et == 0 {
        require_mint_paused(&ctx.accounts.mint_account)?;
        state.next_unpause_et = clock.unix_timestamp + state.delay;
        emit!(UnpauseRequest {
            et: state.next_unpause_et,
        });
        return Ok(());
    }

    // Call 2: execute once the delay has elapsed.
    require!(
        state.next_unpause_et <= clock.unix_timestamp,
        ErrorCode::NotEffective
    );
    state.next_unpause_et = 0;

    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    let instruction = resume(
        &ctx.accounts.token_program.key(),
        &ctx.accounts.mint_account.key(),
        &ctx.accounts.mint_account.key(),    // authority
        &[&ctx.accounts.mint_account.key()], // signers
    )?;

    anchor_lang::solana_program::program::invoke_signed(
        &instruction,
        &[ctx.accounts.mint_account.to_account_info()],
        signer_seeds,
    )?;

    emit!(Unpaused {
        caller: ctx.accounts.owner.key()
    });
    Ok(())
}

fn require_mint_paused(mint_account: &InterfaceAccount<Mint>) -> Result<()> {
    let mint_info = mint_account.to_account_info();
    let mint_data = mint_info.try_borrow_data()?;
    let mint_state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&mint_data)?;
    let pausable = mint_state.get_extension::<PausableConfig>()?;
    require!(bool::from(pausable.paused), ErrorCode::NotPaused);
    Ok(())
}
