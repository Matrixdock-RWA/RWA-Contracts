use {
    anchor_lang::prelude::*,
    anchor_spl::{
        associated_token::AssociatedToken,
        token_interface::{self, Burn, Mint, Token2022, TokenAccount},
    },
};

use super::super::mtoken::{errors::ErrorCode, events::Redeem, state::State};

#[derive(Accounts)]
pub struct RedeemToken<'info> {
    #[account(mut)]
    pub operator: Signer<'info>,

    // Mint account address is a PDA
    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    // This is the account that will hold the minted tokens
    #[account(
        init_if_needed,
        payer = operator,
        associated_token::mint = mint_account,
        associated_token::authority = operator,
        token::token_program = token_program,
    )]
    pub associated_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = operator @ ErrorCode::NotOperator,
    )]
    state: Account<'info, State>,

    pub token_program: Program<'info, Token2022>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn redeem_token(
    ctx: Context<RedeemToken>,
    amount: u64,
    customer: Pubkey,
    data: Vec<u8>,
) -> Result<()> {
    // Invoke the burn instruction on the token program
    token_interface::burn(
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
