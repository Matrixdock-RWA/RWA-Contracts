use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    self, FreezeAccount, Mint, ThawAccount, Token2022, TokenAccount, TransferChecked,
};

use super::super::mtoken::{
    errors::ErrorCode,
    events::{ForceTransfer, ForcedTransferRequest},
    state::State,
};

#[derive(Accounts)]
pub struct ForcedTransferTokens<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner @ ErrorCode::NotOwner,
    )]
    state: Account<'info, State>,

    #[account(mut)]
    owner: Signer<'info>,

    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub sender_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Program<'info, Token2022>,
}

// Two-call delayed pattern (mirrors mint_token):
//   Call 1 (et == 0): validate, record request, emit ForcedTransferRequest, return.
//   Call 2 (et != 0): verify delay elapsed + params match, execute transfer, emit ForceTransfer.
pub fn forced_transfer_tokens(
    ctx: Context<ForcedTransferTokens>,
    amount: u64,
    nonce: [u8; 32],
    data: Vec<u8>,
    extra_data: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;

    let from = ctx.accounts.sender_token_account.key();
    let to = ctx.accounts.recipient_token_account.key();

    // sender must be blocked (frozen) on both calls
    require!(
        ctx.accounts.sender_token_account.is_frozen(),
        ErrorCode::NotBlocked
    );

    // destination locked to admin-configured receiver
    require!(
        to == state.forced_transfer_receiver,
        ErrorCode::InvalidForcedTransferReceiver
    );

    // Call 1: create request
    if state.next_forced_transfer_et == 0 {
        let et = clock.unix_timestamp + state.delay;
        state.next_forced_transfer_from = from;
        state.next_forced_transfer_to = to;
        state.next_forced_transfer_amount = amount;
        state.next_forced_transfer_et = et;
        state.next_forced_transfer_nonce = nonce;
        emit!(ForcedTransferRequest {
            from,
            to,
            amount,
            data: data.clone(),
            extra_data: extra_data.clone()
        });
        return Ok(());
    }

    // Call 2: execute
    // Note: data/extra_data are informational only and not stored in state, so they
    // are not validated here. The EVM version implicitly validates them via the request
    // hash, but Solana's single-slot model cannot replicate this without storing the
    // fields (which would require a state layout change). The ForceTransfer event may
    // therefore carry different data/extra_data than the ForcedTransferRequest event.
    require!(
        state.next_forced_transfer_et <= clock.unix_timestamp,
        ErrorCode::TooEarlyToForcedTransfer
    );
    require!(
        state.next_forced_transfer_from == from
            && state.next_forced_transfer_to == to
            && state.next_forced_transfer_amount == amount
            && state.next_forced_transfer_nonce == nonce,
        ErrorCode::RequestMismatch
    );

    state.next_forced_transfer_et = 0;

    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];
    let decimals = ctx.accounts.mint_account.decimals;

    // sender is frozen — thaw, transfer, re-freeze if tokens remain
    token_interface::thaw_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        ThawAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.sender_token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(),
        },
        signer_seeds,
    ))?;

    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                mint: ctx.accounts.mint_account.to_account_info(),
                from: ctx.accounts.sender_token_account.to_account_info(),
                to: ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
        amount,
        decimals,
    )?;

    // Prevent forced transfer from draining sender account to zero (which would
    // allow the account to be closed and reopened unfrozen).
    ctx.accounts.sender_token_account.reload()?;
    require!(
        ctx.accounts.sender_token_account.amount > 0,
        ErrorCode::TransferWouldDrainAccount
    );

    token_interface::freeze_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        FreezeAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.sender_token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(),
        },
        signer_seeds,
    ))?;

    emit!(ForceTransfer {
        from,
        to,
        amount,
        data,
        extra_data
    });
    Ok(())
}
