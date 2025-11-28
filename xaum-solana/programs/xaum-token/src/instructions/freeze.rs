use {
    anchor_lang::prelude::*,
    anchor_spl::token_interface::{self, FreezeAccount, Mint, Token2022, TokenAccount},
};

use super::super::mtoken::{errors::ErrorCode, events::BlockPlaced, state::State};

#[derive(Accounts)]
pub struct Freeze<'info> {
    pub operator: Signer<'info>,

    // Mint account address is a PDA
    #[account(
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub target_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,

    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

// we only allow freezing if the token account has a non-zero balance!
pub fn freeze(ctx: Context<Freeze>) -> Result<()> {
    require!(
        ctx.accounts.target_token_account.amount > 0,
        ErrorCode::TokenBalanceZero
    );

    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    // Invoke the freeze instruction on the token program
    token_interface::freeze_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        FreezeAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.target_token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(), // PDA mint authority, required as signer
        },
        signer_seeds,
    ))?;

    emit!(BlockPlaced {
        user: ctx.accounts.target_token_account.key()
    });

    Ok(())
}
