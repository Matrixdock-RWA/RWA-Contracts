// https://github.com/solana-developers/program-examples/blob/main/tokens/token-2022/transfer-fee/anchor/programs/transfer-fee/src/instructions/withdraw.rs

use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    withdraw_withheld_tokens_from_mint, Mint, Token2022, TokenAccount,
    WithdrawWithheldTokensFromMint,
};

use super::super::mtoken::{errors::ErrorCode, state::State};

#[derive(Accounts)]
pub struct Withdraw<'info> {
    pub operator: Signer<'info>,

    #[account(
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

    #[account(mut)]
    pub token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Program<'info, Token2022>,
}

// transfer fees "harvested" to the mint account can then be withdraw by the withdraw authority
// this transfers fees on the mint account to the specified token account
pub fn process_withdraw(ctx: Context<Withdraw>) -> Result<()> {
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    withdraw_withheld_tokens_from_mint(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            WithdrawWithheldTokensFromMint {
                token_program_id: ctx.accounts.token_program.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
                destination: ctx.accounts.token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
    )?;
    Ok(())
}
