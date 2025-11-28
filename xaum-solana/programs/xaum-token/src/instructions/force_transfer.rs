use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    self, FreezeAccount, Mint, ThawAccount, Token2022, TokenAccount, TransferChecked,
};

use super::super::mtoken::{errors::ErrorCode, events::ForceTransfer, state::State};

#[derive(Accounts)]
pub struct ForceTransferTokens<'info> {
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

pub fn force_transfer_tokens(ctx: Context<ForceTransferTokens>, amount: u64) -> Result<()> {
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    let decimals = ctx.accounts.mint_account.decimals;
    let sender_is_frozen = ctx.accounts.sender_token_account.is_frozen();

    if sender_is_frozen {
        token_interface::thaw_account(CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            ThawAccount {
                mint: ctx.accounts.mint_account.to_account_info(),
                account: ctx.accounts.sender_token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(), // PDA mint authority, required as signer
            },
            signer_seeds,
        ))?;
    }
    let cpi_accounts = TransferChecked {
        mint: ctx.accounts.mint_account.to_account_info(),
        from: ctx.accounts.sender_token_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.mint_account.to_account_info(),
    };
    let cpi_program = ctx.accounts.token_program.to_account_info();
    // PDA signer seeds
    let cpi_context = CpiContext::new(cpi_program, cpi_accounts).with_signer(signer_seeds);
    token_interface::transfer_checked(cpi_context, amount, decimals)?;

    ctx.accounts.sender_token_account.reload()?;
    if sender_is_frozen && ctx.accounts.sender_token_account.amount > 0 {
        token_interface::freeze_account(CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            FreezeAccount {
                mint: ctx.accounts.mint_account.to_account_info(),
                account: ctx.accounts.sender_token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(), // PDA mint authority, required as signer
            },
            signer_seeds,
        ))?;
    }
    emit!(ForceTransfer {
        from: ctx.accounts.sender_token_account.key(),
        to: ctx.accounts.recipient_token_account.key(),
        amount,
    });
    Ok(())
}
