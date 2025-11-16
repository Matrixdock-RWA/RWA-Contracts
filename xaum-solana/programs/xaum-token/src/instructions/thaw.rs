use {
    anchor_lang::prelude::*,
    anchor_spl::token::{thaw_account, Mint, ThawAccount, Token, TokenAccount},
};

use super::super::mtoken::{errors::ErrorCode, events::BlockReleased, state::State};

#[derive(Accounts)]
pub struct Thaw<'info> {
    pub operator: Signer<'info>,

    // Mint account address is a PDA
    #[account(
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: Account<'info, Mint>,

    #[account(mut)]
    pub token_account: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn thaw(ctx: Context<Thaw>) -> Result<()> {
    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    // Invoke the thaw instruction on the token program
    thaw_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        ThawAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(), // PDA mint authority, required as signer
        },
        signer_seeds,
    ))?;

    emit!(BlockReleased {
        user: ctx.accounts.token_account.key()
    });

    Ok(())
}
