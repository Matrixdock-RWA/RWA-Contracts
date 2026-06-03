use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};

declare_id!("7oRKE73rQCQ13hrmGrVUmUwg7S6LzEV8yuV3GTgAzjGY");

pub const DELAY_MAX: i64 = 59;
pub const MAX_ACCEPTED_TOKENS: usize = 10;
// Ownership transfer timelock: request must wait this long before taking effect.
pub const OWNER_TRANSFER_DELAY: i64 = 12 * 3600; // 12 hours

#[program]
pub mod xaum_minter {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        pool_account_a: Pubkey,
        pool_account_b: Pubkey,
        tokens_accepted_by_a: Vec<Pubkey>,
        tokens_accepted_by_b: Vec<Pubkey>,
    ) -> Result<()> {
        require!(
            tokens_accepted_by_a.len() <= MAX_ACCEPTED_TOKENS,
            ErrorCode::ExceedsMaxAcceptedTokens
        );
        require!(
            tokens_accepted_by_b.len() <= MAX_ACCEPTED_TOKENS,
            ErrorCode::ExceedsMaxAcceptedTokens
        );
        let state = &mut ctx.accounts.state;
        let owner = *ctx.accounts.owner.key;
        state.owner = owner;
        state.next_owner = owner;
        state.next_owner_et = 0;
        state.pool_account_a = pool_account_a;
        state.pool_account_b = pool_account_b;
        state.accepted_by_a = tokens_accepted_by_a;
        state.accepted_by_b = tokens_accepted_by_b;
        state.bump = ctx.bumps.state;
        Ok(())
    }

    // Two-step ownership transfer with a hardcoded 12-hour timelock.
    // Step 1 (owner): records the pending new owner and starts the countdown.
    // Step 2 (new owner): the pending owner calls accept_ownership after the delay.
    // A pending transfer must be revoked before a new one can be started.
    pub fn transfer_ownership(ctx: Context<OnlyOwner>, new_owner: Pubkey) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(state.next_owner_et == 0, ErrorCode::PendingOwnerExist);
        let clock = Clock::get()?;
        state.next_owner = new_owner;
        state.next_owner_et = clock.unix_timestamp + OWNER_TRANSFER_DELAY;
        emit!(SetOwnerRequest {
            old_owner: state.owner,
            new_owner,
            et: state.next_owner_et,
        });
        Ok(())
    }

    // Step 2: the pending owner (next_owner) accepts the transfer once the timelock elapses.
    pub fn accept_ownership(ctx: Context<AcceptOwner>) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(state.next_owner_et != 0, ErrorCode::NoPendingOwner);
        let clock = Clock::get()?;
        require!(
            state.next_owner_et <= clock.unix_timestamp,
            ErrorCode::NotEffective
        );
        state.owner = state.next_owner;
        state.next_owner_et = 0;
        emit!(SetOwnerEffected {
            new_owner: state.owner,
        });
        Ok(())
    }

    // Owner can cancel a pending ownership transfer before it takes effect.
    pub fn revoke_next_owner(ctx: Context<OnlyOwner>) -> Result<()> {
        ctx.accounts.state.next_owner_et = 0;
        Ok(())
    }

    pub fn set_pool_account_a(ctx: Context<OnlyOwner>, new_pool_a: Pubkey) -> Result<()> {
        let state = &mut ctx.accounts.state;
        state.pool_account_a = new_pool_a;
        emit!(SetPoolAccountAEvent {
            pool_account_a: new_pool_a,
        });
        Ok(())
    }

    pub fn set_pool_account_b(ctx: Context<OnlyOwner>, new_pool_b: Pubkey) -> Result<()> {
        let state = &mut ctx.accounts.state;
        state.pool_account_b = new_pool_b;
        emit!(SetPoolAccountBEvent {
            pool_account_b: new_pool_b,
        });
        Ok(())
    }

    pub fn set_accepted_by_a(ctx: Context<OnlyOwner>, token: Pubkey, accepted: bool) -> Result<()> {
        let state = &mut ctx.accounts.state;
        if accepted {
            if !state.accepted_by_a.contains(&token) {
                require!(
                    state.accepted_by_a.len() < MAX_ACCEPTED_TOKENS,
                    ErrorCode::ExceedsMaxAcceptedTokens
                );
                state.accepted_by_a.push(token);
            }
        } else {
            state.accepted_by_a.retain(|x| x != &token);
        }
        emit!(SetAcceptedByAEvent { token, accepted });
        Ok(())
    }

    pub fn set_accepted_by_b(ctx: Context<OnlyOwner>, token: Pubkey, accepted: bool) -> Result<()> {
        let state = &mut ctx.accounts.state;
        if accepted {
            if !state.accepted_by_b.contains(&token) {
                require!(
                    state.accepted_by_b.len() < MAX_ACCEPTED_TOKENS,
                    ErrorCode::ExceedsMaxAcceptedTokens
                );
                state.accepted_by_b.push(token);
            }
        } else {
            state.accepted_by_b.retain(|x| x != &token);
        }
        emit!(SetAcceptedByBEvent { token, accepted });
        Ok(())
    }

    // preprice and slippage are client-provided hints, not validated on-chain
    pub fn request_to_mint(
        ctx: Context<RequestMint>,
        transferred_token: Pubkey,
        for_token: Pubkey,
        amount: u64,
        preprice: u64,
        slippage: u64,
        timestamp: i64,
        extra_data: Vec<u8>,
    ) -> Result<()> {
        let state = &ctx.accounts.state;
        require!(
            state.accepted_by_b.contains(&for_token) && for_token == ctx.accounts.for_token.key(),
            ErrorCode::InvalidForToken
        );
        require!(
            state.accepted_by_a.contains(&transferred_token)
                && transferred_token == ctx.accounts.transferred_token.key(),
            ErrorCode::InvalidTokenForMinting
        );
        require!(
            state.pool_account_a == ctx.accounts.pool_account_a.key(),
            ErrorCode::InvalidPoolAccountA
        );
        let clock = Clock::get()?;
        require!(
            clock.unix_timestamp <= timestamp + DELAY_MAX,
            ErrorCode::InvalidTimestamp
        );
        let decimals = ctx.accounts.transferred_token.decimals;
        token_interface::transfer_checked(
            ctx.accounts.into_transfer_to_pool_a_ctx(),
            amount,
            decimals,
        )?;
        emit!(MintRequestEvent {
            transferred_token,
            for_token,
            requestor: ctx.accounts.requestor.key(),
            pool: state.pool_account_a,
            pool_ata: ctx.accounts.pool_token_account_a.key(),
            amount,
            preprice,
            slippage,
            extra_data,
        });
        Ok(())
    }

    pub fn request_to_redeem(
        ctx: Context<RequestRedeem>,
        transferred_token: Pubkey,
        for_token: Pubkey,
        amount: u64,
        preprice: u64,
        slippage: u64,
        timestamp: i64,
        extra_data: Vec<u8>,
    ) -> Result<()> {
        let state = &ctx.accounts.state;
        require!(
            state.accepted_by_a.contains(&for_token),
            ErrorCode::InvalidForToken
        );
        require!(
            state.accepted_by_b.contains(&transferred_token)
                && transferred_token == ctx.accounts.transferred_token.key(),
            ErrorCode::InvalidTokenForRedeeming
        );
        require!(
            state.pool_account_b == ctx.accounts.pool_account_b.key(),
            ErrorCode::InvalidPoolAccountB
        );
        let clock = Clock::get()?;
        require!(
            clock.unix_timestamp <= timestamp + DELAY_MAX,
            ErrorCode::InvalidTimestamp
        );
        let decimals = ctx.accounts.transferred_token.decimals;
        token_interface::transfer_checked(
            ctx.accounts.into_transfer_to_pool_b_ctx(),
            amount,
            decimals,
        )?;
        emit!(RedeemRequestEvent {
            transferred_token,
            for_token,
            requestor: ctx.accounts.requestor.key(),
            pool: state.pool_account_b,
            pool_ata: ctx.accounts.pool_token_account_b.key(),
            amount,
            preprice,
            slippage,
            extra_data,
        });
        Ok(())
    }
}

// ------- Events Definitions -------

#[event]
pub struct SetOwnerRequest {
    pub old_owner: Pubkey,
    pub new_owner: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetOwnerEffected {
    pub new_owner: Pubkey,
}

#[event]
pub struct SetPoolAccountAEvent {
    pub pool_account_a: Pubkey,
}

#[event]
pub struct SetPoolAccountBEvent {
    pub pool_account_b: Pubkey,
}

#[event]
pub struct SetAcceptedByAEvent {
    pub token: Pubkey,
    pub accepted: bool,
}

#[event]
pub struct SetAcceptedByBEvent {
    pub token: Pubkey,
    pub accepted: bool,
}

#[event]
pub struct MintRequestEvent {
    pub transferred_token: Pubkey,
    pub for_token: Pubkey,
    pub requestor: Pubkey,
    pub pool: Pubkey,
    pub pool_ata: Pubkey,
    pub amount: u64,
    /// client-provided off-chain pricing hint
    pub preprice: u64,
    /// client-provided off-chain pricing hint
    pub slippage: u64,
    pub extra_data: Vec<u8>,
}

#[event]
pub struct RedeemRequestEvent {
    pub transferred_token: Pubkey,
    pub for_token: Pubkey,
    pub requestor: Pubkey,
    pub pool: Pubkey,
    pub pool_ata: Pubkey,
    pub amount: u64,
    /// client-provided off-chain pricing hint
    pub preprice: u64,
    /// client-provided off-chain pricing hint
    pub slippage: u64,
    pub extra_data: Vec<u8>,
}

// ------- Account Definitions -------

#[account]
#[derive(InitSpace)]
pub struct State {
    pub owner: Pubkey,
    pub next_owner: Pubkey,
    pub next_owner_et: i64,
    pub pool_account_a: Pubkey,
    pub pool_account_b: Pubkey,
    #[max_len(MAX_ACCEPTED_TOKENS)]
    pub accepted_by_a: Vec<Pubkey>,
    #[max_len(MAX_ACCEPTED_TOKENS)]
    pub accepted_by_b: Vec<Pubkey>,
    pub bump: u8,
}

// -------- Context Definitions --------

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        seeds = [b"state"],
        bump,
        payer = owner,
        space = 8 + State::INIT_SPACE,
    )]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub owner: Signer<'info>,

    #[ account(address = crate::ID) ]
    pub program: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct OnlyOwner<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner,
    )]
    pub state: Account<'info, State>,
    pub owner: Signer<'info>,
}

// Signed by the pending owner (next_owner) to accept a timelocked ownership transfer.
#[derive(Accounts)]
pub struct AcceptOwner<'info> {
    #[account(
        mut,
        seeds = [b"state"],
        bump = state.bump,
        has_one = next_owner @ ErrorCode::NotNextOwner,
    )]
    pub state: Account<'info, State>,
    pub next_owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct RequestMint<'info> {
    #[account(
        seeds = [b"state"],
        bump = state.bump,
    )]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub requestor: Signer<'info>,

    /// CHECK: token mint of transferred token
    #[account(
        mint::token_program = token_program_transferred_token
    )]
    pub transferred_token: Box<InterfaceAccount<'info, Mint>>,

    /// The ATA of the requestor for transferred_token
    #[account(mut,
        associated_token::mint = transferred_token,
        associated_token::authority = requestor,
        associated_token::token_program = token_program_transferred_token
    )]
    pub requestor_transferred_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: token mint of for token
    #[account(
        mint::token_program = token_program_for_token
    )]
    pub for_token: Box<InterfaceAccount<'info, Mint>>,

    /// The ATA of the requestor for for_token
    #[account(
        init_if_needed,
        payer = requestor,
        associated_token::mint = for_token,
        associated_token::authority = requestor,
        associated_token::token_program = token_program_for_token,
    )]
    pub for_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    /// The pool_account_a's ATA to receive tokens
    #[account(mut,
        associated_token::mint = transferred_token,
        associated_token::authority = pool_account_a,
        associated_token::token_program = token_program_transferred_token
    )]
    pub pool_token_account_a: Box<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: pool account A
    pub pool_account_a: AccountInfo<'info>,

    pub token_program_transferred_token: Interface<'info, TokenInterface>,

    pub token_program_for_token: Interface<'info, TokenInterface>,

    pub associated_token_program: Program<'info, AssociatedToken>,

    pub system_program: Program<'info, System>,
}

impl<'info> RequestMint<'info> {
    fn into_transfer_to_pool_a_ctx(&self) -> CpiContext<'_, '_, '_, 'info, TransferChecked<'info>> {
        let cpi_accounts = TransferChecked {
            mint: self.transferred_token.to_account_info(),
            from: self.requestor_transferred_token_account.to_account_info(),
            to: self.pool_token_account_a.to_account_info(),
            authority: self.requestor.to_account_info(),
        };
        CpiContext::new(
            self.token_program_transferred_token.to_account_info(),
            cpi_accounts,
        )
    }
}

#[derive(Accounts)]
pub struct RequestRedeem<'info> {
    #[account(
        seeds = [b"state"],
        bump = state.bump,
    )]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub requestor: Signer<'info>,

    /// CHECK: token mint of transferred token
    #[account(
        mint::token_program = token_program_transferred_token
    )]
    pub transferred_token: Box<InterfaceAccount<'info, Mint>>,

    /// The ATA of the requestor for transferred_token
    #[account(mut,
        associated_token::mint = transferred_token,
        associated_token::authority = requestor,
        associated_token::token_program = token_program_transferred_token
    )]
    pub requestor_transferred_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    /// The pool_account_b's ATA to receive tokens
    #[account(mut,
        associated_token::mint = transferred_token,
        associated_token::authority = pool_account_b,
        associated_token::token_program = token_program_transferred_token
    )]
    pub pool_token_account_b: Box<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: pool account b
    pub pool_account_b: AccountInfo<'info>,

    pub token_program_transferred_token: Interface<'info, TokenInterface>,
}

impl<'info> RequestRedeem<'info> {
    fn into_transfer_to_pool_b_ctx(&self) -> CpiContext<'_, '_, '_, 'info, TransferChecked<'info>> {
        let cpi_accounts = TransferChecked {
            mint: self.transferred_token.to_account_info(),
            from: self.requestor_transferred_token_account.to_account_info(),
            to: self.pool_token_account_b.to_account_info(),
            authority: self.requestor.to_account_info(),
        };
        CpiContext::new(
            self.token_program_transferred_token.to_account_info(),
            cpi_accounts,
        )
    }
}

#[error_code]
pub enum ErrorCode {
    #[msg("INVALID_TOKEN_FOR_MINTING")]
    InvalidTokenForMinting,
    #[msg("INVALID_TOKEN_FOR_REDEEMING")]
    InvalidTokenForRedeeming,
    #[msg("INVALID_TIMESTAMP")]
    InvalidTimestamp,
    #[msg("INVALID_POOL_ACCOUNT_A")]
    InvalidPoolAccountA,
    #[msg("INVALID_POOL_ACCOUNT_B")]
    InvalidPoolAccountB,
    #[msg("EXCEEDS_MAX_ACCEPTED_TOKENS")]
    ExceedsMaxAcceptedTokens,
    #[msg("InvalidForToken")]
    InvalidForToken,
    #[msg("NotEffective")]
    NotEffective,
    #[msg("RequestMismatch")]
    RequestMismatch,
    #[msg("NotNextOwner")]
    NotNextOwner,
    #[msg("PendingOwnerExist")]
    PendingOwnerExist,
    #[msg("NoPendingOwner")]
    NoPendingOwner,
}
