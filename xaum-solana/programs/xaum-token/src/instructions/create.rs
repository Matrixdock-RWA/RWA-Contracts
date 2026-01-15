// https://github.com/solana-developers/program-examples/blob/main/tokens/token-2022/transfer-fee/anchor/programs/transfer-fee/src/instructions/initialize.rs

use {
    anchor_lang::prelude::*,
    anchor_lang::system_program::{create_account, CreateAccount},
    anchor_spl::token_interface::{
        initialize_mint2, metadata_pointer_initialize, permanent_delegate_initialize,
        token_metadata_initialize, transfer_fee_initialize, InitializeMint2,
        MetadataPointerInitialize, PermanentDelegateInitialize, Token2022, TokenMetadataInitialize,
        TransferFeeInitialize,
    },
    spl_token_2022::{
        extension::{pausable::instruction::initialize as pausable_initialize, ExtensionType},
        pod::PodMint,
    },
};

use super::super::mtoken::utils::update_account_lamports_to_minimum_rent_balance;
use super::super::mtoken::xaum::MAX_ACCEPTABLE_DELAY;
use super::super::mtoken::{errors::ErrorCode, state::State, xaum::XAUM_DECIMALS};

#[derive(Accounts)]
pub struct CreateToken<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[ account(address = crate::ID) ]
    pub program: Signer<'info>,

    /// CHECK: Mint account PDA, will be created and initialized manually
    #[account(mut)]
    pub mint_account: UncheckedAccount<'info>,

    #[account(
        init,
        payer = payer,
        space = 8 + State::INIT_SPACE,
        seeds = [b"state"],
        bump
    )]
    pub state: Box<Account<'info, State>>,

    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

pub fn create_token(
    ctx: Context<CreateToken>,
    token_name: String,
    token_symbol: String,
    token_uri: String,
    delay: i64,
) -> Result<()> {
    require!(delay >= 0, ErrorCode::NegativeDelay); // zero is allowed for initialization scenarios
    require!(
        delay <= MAX_ACCEPTABLE_DELAY,
        ErrorCode::DelayExceedsMaximum
    );

    // Initialize state
    let state = &mut ctx.accounts.state;
    let bump = ctx.bumps.state;
    let payer = *ctx.accounts.payer.key;
    state.init(payer, delay, bump);
    msg!("state initialized");

    // Verify mint account PDA
    let (mint_pda, mint_bump) = check_mint_account(&ctx)?;
    msg!("mint_pda: {}, bump: {}", mint_pda, mint_bump);

    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[mint_bump]]];

    // Invoke System Program to create new account with space for mint and extension data
    create_mint_account(&ctx, signer_seeds)?;
    msg!("mint_account created");

    // Initialize extensions BEFORE mint init (order matters!)
    init_metadata_pointer(&ctx)?;
    init_permanent_delegate(&ctx)?;
    init_transfer_fee(&ctx)?;
    init_pausable(&ctx)?;
    msg!("extensions initialized");

    // Initialize the standard mint account data
    init_mint2(&ctx)?;
    msg!("mint initialized");

    // Initialize token metadata (after mint init)
    init_metadata(&ctx, token_name, token_symbol, token_uri, signer_seeds)?;
    msg!("metadata initialized");

    Ok(())
}

fn check_mint_account(ctx: &Context<CreateToken>) -> Result<(Pubkey, u8)> {
    let (mint_pda, mint_bump) = Pubkey::find_program_address(&[b"mint"], ctx.program_id);
    require!(
        mint_pda == *ctx.accounts.mint_account.key,
        anchor_lang::error::ErrorCode::ConstraintSeeds
    );
    Ok((mint_pda, mint_bump))
}

fn create_mint_account(ctx: &Context<CreateToken>, signer_seeds: &[&[&[u8]]]) -> Result<()> {
    // Calculate space required for mint and extension data
    let mint_size = ExtensionType::try_calculate_account_len::<PodMint>(&[
        ExtensionType::MetadataPointer,
        ExtensionType::PermanentDelegate,
        ExtensionType::TransferFeeConfig,
        ExtensionType::Pausable,
    ])?;

    // Calculate minimum lamports required for size of mint account with extensions
    let lamports = (Rent::get()?).minimum_balance(mint_size);

    create_account(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            CreateAccount {
                from: ctx.accounts.payer.to_account_info(),
                to: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
        lamports,                          // Lamports
        mint_size as u64,                  // Space
        &ctx.accounts.token_program.key(), // Owner Program
    )?;

    Ok(())
}

fn init_mint2(ctx: &Context<CreateToken>) -> Result<()> {
    initialize_mint2(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            InitializeMint2 {
                mint: ctx.accounts.mint_account.to_account_info(),
            },
        ),
        XAUM_DECIMALS,                          // decimals
        &ctx.accounts.mint_account.key(),       // mint authority
        Some(&ctx.accounts.mint_account.key()), // freeze authority
    )
}

// Initialize metadata pointer extension BEFORE mint init
// This must be called before initialize_mint
fn init_metadata_pointer(ctx: &Context<CreateToken>) -> Result<()> {
    metadata_pointer_initialize(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            MetadataPointerInitialize {
                token_program_id: ctx.accounts.token_program.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
            },
        ),
        Some(ctx.accounts.mint_account.key()), // authority
        Some(ctx.accounts.mint_account.key()), // metadata_address
    )
}

// Initialize permanent delegate extension BEFORE mint init
// This must be called before initialize_mint
fn init_permanent_delegate(ctx: &Context<CreateToken>) -> Result<()> {
    permanent_delegate_initialize(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            PermanentDelegateInitialize {
                token_program_id: ctx.accounts.token_program.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
            },
        ),
        &ctx.accounts.mint_account.key(), // permanent delegate
    )
}

// Initialize the transfer fee extension data
// This instruction must come before the instruction to initialize the mint data
fn init_transfer_fee(ctx: &Context<CreateToken>) -> Result<()> {
    transfer_fee_initialize(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferFeeInitialize {
                token_program_id: ctx.accounts.token_program.to_account_info(),
                mint: ctx.accounts.mint_account.to_account_info(),
            },
        ),
        Some(&ctx.accounts.mint_account.key()), // transfer fee config authority (update fee)
        Some(&ctx.accounts.mint_account.key()), // withdraw authority (withdraw fees)
        0,                                      // transfer fee basis points (% fee per transfer)
        0,                                      // maximum fee (maximum units of token per transfer)
    )
}

// Initialize the Pausable extension
// This instruction must come before the instruction to initialize the mint data
fn init_pausable(ctx: &Context<CreateToken>) -> Result<()> {
    let instruction = pausable_initialize(
        ctx.accounts.token_program.key,
        ctx.accounts.mint_account.key,
        ctx.accounts.mint_account.key, // pause authority
    )?;
    anchor_lang::solana_program::program::invoke(
        &instruction,
        &[ctx.accounts.mint_account.to_account_info()],
    )?;

    Ok(())
}

fn init_metadata(
    ctx: &Context<CreateToken>,
    token_name: String,
    token_symbol: String,
    token_uri: String,
    signer_seeds: &[&[&[u8]]],
) -> Result<()> {
    let cpi_accounts = TokenMetadataInitialize {
        program_id: ctx.accounts.token_program.to_account_info(),
        mint: ctx.accounts.mint_account.to_account_info(),
        metadata: ctx.accounts.mint_account.to_account_info(), // metadata account is the mint, since data is stored in mint
        mint_authority: ctx.accounts.mint_account.to_account_info(),
        update_authority: ctx.accounts.mint_account.to_account_info(),
    };
    let cpi_ctx = CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts)
        .with_signer(signer_seeds);
    token_metadata_initialize(cpi_ctx, token_name, token_symbol, token_uri)?;

    // Note: AccountInfo's data_len() and get_lamports() always return the latest values
    // directly from the runtime, so no reload is needed even after metadata initialization.
    update_account_lamports_to_minimum_rent_balance(
        ctx.accounts.mint_account.to_account_info(),
        ctx.accounts.payer.to_account_info(),
        ctx.accounts.system_program.to_account_info(),
    )
}
