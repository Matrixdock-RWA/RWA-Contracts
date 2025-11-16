use {
    anchor_lang::prelude::*,
    anchor_spl::{
        associated_token::AssociatedToken,
        token::{burn, Burn, Mint, Token, TokenAccount},
    },
};

use super::super::mtoken::{errors::ErrorCode, events::Redeem, state::State};

#[derive(Accounts)]
pub struct RedeemToken<'info> {
    pub operator: Signer<'info>,

    // Mint account address is a PDA
    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: Account<'info, Mint>,

    // Create Associated Token Account, if needed
    // This is the account that will hold the minted tokens
    #[account(
        mut,
        associated_token::mint = mint_account,
        associated_token::authority = operator,
    )]
    pub associated_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn redeem_token(
    ctx: Context<RedeemToken>,
    amount: u64,
    customer: Pubkey,
    data: Vec<u8>,
) -> Result<()> {
    msg!("redeem_token...");
    msg!("mint_account: {}", &ctx.accounts.mint_account.key());
    msg!("ATA: {}", &ctx.accounts.associated_token_account.key());

    // Invoke the burn instruction on the token program
    burn(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Burn {
                mint: ctx.accounts.mint_account.to_account_info(),
                from: ctx.accounts.associated_token_account.to_account_info(),
                authority: ctx.accounts.operator.to_account_info(),
            },
        ),
        amount,
    )?;

    ctx.accounts.state.mint_budget += amount;

    emit!(Redeem {
        customer,
        amount,
        data
    });

    Ok(())
}
