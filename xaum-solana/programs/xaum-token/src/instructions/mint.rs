use {
    anchor_lang::prelude::*,
    anchor_spl::{
        associated_token::AssociatedToken,
        token_interface::{self, Mint, MintTo, Token2022, TokenAccount},
    },
};

use super::super::mtoken::{
    errors::ErrorCode,
    events::{MintEffected, MintRequest},
    state::State,
};

#[derive(Accounts)]
pub struct MintToken<'info> {
    #[account(mut)]
    pub operator: Signer<'info>,

    /// CHECK: recipient account can be a PDA or multisig
    pub recipient: UncheckedAccount<'info>,

    // ATA must be initialized before minting
    #[account(
        mut,
        associated_token::mint = mint_account,
        associated_token::authority = recipient,
        associated_token::token_program = token_program,
    )]
    pub associated_token_account: InterfaceAccount<'info, TokenAccount>,

    // Mint account address is a PDA
    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

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

pub fn mint_token(ctx: Context<MintToken>, amount: u64, nonce: [u8; 32]) -> Result<()> {
    let recipient_key = ctx.accounts.recipient.key();
    let state = &mut ctx.accounts.state;

    let clock = Clock::get()?;
    if state.next_mint_et == 0 {
        state.next_mint_recipient = recipient_key;
        state.next_mint_et = clock.unix_timestamp + state.delay;
        state.next_mint_amount = amount;
        state.next_mint_nonce = nonce;
        emit!(MintRequest {
            recipient: recipient_key,
            amount,
            nonce,
            et: state.next_mint_et,
        });
        return Ok(());
    }

    require!(
        state.next_mint_recipient == recipient_key && state.next_mint_amount == amount,
        ErrorCode::IncorrectMintInfo,
    );
    require!(
        state.next_mint_et <= clock.unix_timestamp,
        ErrorCode::NotEffective
    );
    require!(state.next_mint_nonce == nonce, ErrorCode::IncorrectMintInfo,);
    state.next_mint_et = 0;

    require!(state.mint_budget >= amount, ErrorCode::MintBudgetNotEnough);
    state.mint_budget -= amount;

    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    // Invoke the mint_to instruction on the token program
    token_interface::mint_to(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint: ctx.accounts.mint_account.to_account_info(),
                to: ctx.accounts.associated_token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(), // PDA mint authority, required as signer
            },
        )
        .with_signer(signer_seeds), // using PDA to sign
        amount,
    )?;

    emit!(MintEffected {
        recipient: recipient_key,
        amount,
        nonce,
    });

    Ok(())
}
