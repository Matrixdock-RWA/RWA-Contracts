use {
    anchor_lang::prelude::*,
    anchor_spl::{
        associated_token::{
            create_idempotent as create_ata, get_associated_token_address as get_ata,
            AssociatedToken, Create,
        },
        token::{mint_to, Mint, MintTo, Token},
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

    /// CHECK: we will check the ATA later since it's may not initialized yet
    #[account(mut)]
    pub associated_token_account: UncheckedAccount<'info>,

    // Mint account address is a PDA
    #[account(
        mut,
        seeds = [b"mint"],
        bump
    )]
    pub mint_account: Account<'info, Mint>,

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

pub fn mint_token(ctx: Context<MintToken>, amount: u64, nonce: [u8; 32]) -> Result<()> {
    let recipient_key = ctx.accounts.recipient.key();
    let state = &mut ctx.accounts.state;

    // check ATA
    let expected_ata = get_ata(&recipient_key, &ctx.accounts.mint_account.key());
    require!(
        expected_ata == *ctx.accounts.associated_token_account.key,
        ErrorCode::InvalidATA,
    );

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

    // create ATA if not initialized
    if ctx.accounts.associated_token_account.lamports() == 0 {
        let cpi_ctx = CpiContext::new(
            ctx.accounts.associated_token_program.to_account_info(),
            Create {
                payer: ctx.accounts.operator.to_account_info(),
                associated_token: ctx.accounts.associated_token_account.to_account_info(),
                authority: ctx.accounts.recipient.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
                token_program: ctx.accounts.token_program.to_account_info(),
            },
        );
        create_ata(cpi_ctx)?;
    }

    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    // Invoke the mint_to instruction on the token program
    mint_to(
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
