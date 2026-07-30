use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak;
use anchor_spl::token_interface::{
    self, FreezeAccount, Mint, ThawAccount, Token2022, TokenAccount, TransferChecked,
};

use super::super::mtoken::{
    errors::ErrorCode,
    events::{ForceTransfer, ForcedTransferRequest},
    state::State,
};

#[derive(Accounts)]
pub struct ForcedTransferTokens<'info> {
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

// Domain separator keeps this request hash scoped to this operation and pins
// the field layout below to a version.
const FORCED_TRANSFER_REQUEST_DOMAIN: &[u8] = b"xaum-token:forced_transfer_request:v1";

// Request hash semantically binds the same forced-transfer inputs as the EVM
// reqHash, while using Solana-local canonical bytes for this program.
// It binds Call 2 to the exact from/to/amount/nonce/data/extra_data of Call 1.
//
// data and extra_data are adjacent variable-length fields, so feeding them in raw
// makes the preimage ambiguous: (data=01, extra_data=0203) and (data=0102,
// extra_data=03) concatenate to the same bytes and hash equal, letting Call 2
// re-split the payload and emit a ForceTransfer that diverges from the approved
// ForcedTransferRequest. Hashing each dynamic field to a fixed 32 bytes first makes
// every field in the outer preimage fixed-width, so the encoding is unambiguous.
fn request_hash(
    from: Pubkey,
    to: Pubkey,
    amount: u64,
    nonce: [u8; 32],
    data: &[u8],
    extra_data: &[u8],
) -> [u8; 32] {
    let data_hash = keccak::hash(data).to_bytes();
    let extra_data_hash = keccak::hash(extra_data).to_bytes();
    keccak::hashv(&[
        FORCED_TRANSFER_REQUEST_DOMAIN,
        from.as_ref(),
        to.as_ref(),
        &amount.to_le_bytes(),
        &nonce,
        &data_hash,
        &extra_data_hash,
    ])
    .to_bytes()
}

// Two-call delayed pattern (mirrors mint_token):
//   Call 1 (et == 0): validate, record request hash, emit ForcedTransferRequest, return.
//   Call 2 (et != 0): verify delay elapsed + request hash matches, execute transfer, emit ForceTransfer.
pub fn forced_transfer_tokens(
    ctx: Context<ForcedTransferTokens>,
    amount: u64,
    nonce: [u8; 32],
    data: Vec<u8>,
    extra_data: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let clock = Clock::get()?;

    let from = ctx.accounts.sender_token_account.key();
    let to = ctx.accounts.recipient_token_account.key();

    // sender must be blocked (frozen) on both calls
    require!(
        ctx.accounts.sender_token_account.is_frozen(),
        ErrorCode::NotBlocked
    );

    // destination locked to admin-configured receiver
    require!(
        to == state.forced_transfer_receiver,
        ErrorCode::InvalidForcedTransferReceiver
    );

    // Call 1: create request
    if state.next_forced_transfer_et == 0 {
        let et = clock.unix_timestamp + state.delay;
        state.next_forced_transfer_et = et;
        state.next_forced_transfer_hash = request_hash(from, to, amount, nonce, &data, &extra_data);
        emit!(ForcedTransferRequest {
            from,
            to,
            amount,
            data,
            extra_data
        });
        return Ok(());
    }

    // Call 2: execute — request hash binds this call to the exact from/to/amount/nonce/
    // data/extra_data of the Call 1 request, so ForceTransfer can't diverge from
    // ForcedTransferRequest.
    require!(
        state.next_forced_transfer_et <= clock.unix_timestamp,
        ErrorCode::TooEarlyToForcedTransfer
    );
    require!(
        state.next_forced_transfer_hash
            == request_hash(from, to, amount, nonce, &data, &extra_data),
        ErrorCode::RequestMismatch
    );

    state.next_forced_transfer_et = 0;
    state.next_forced_transfer_hash = [0; 32];

    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];
    let decimals = ctx.accounts.mint_account.decimals;

    // sender is frozen — thaw, transfer, re-freeze if tokens remain
    token_interface::thaw_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        ThawAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.sender_token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(),
        },
        signer_seeds,
    ))?;

    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                mint: ctx.accounts.mint_account.to_account_info(),
                from: ctx.accounts.sender_token_account.to_account_info(),
                to: ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
        amount,
        decimals,
    )?;

    // Prevent forced transfer from draining sender account to zero (which would
    // allow the account to be closed and reopened unfrozen).
    ctx.accounts.sender_token_account.reload()?;
    require!(
        ctx.accounts.sender_token_account.amount > 0,
        ErrorCode::TransferWouldDrainAccount
    );

    token_interface::freeze_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        FreezeAccount {
            mint: ctx.accounts.mint_account.to_account_info(),
            account: ctx.accounts.sender_token_account.to_account_info(),
            authority: ctx.accounts.mint_account.to_account_info(),
        },
        signer_seeds,
    ))?;

    emit!(ForceTransfer {
        from,
        to,
        amount,
        data,
        extra_data
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONCE: [u8; 32] = [3u8; 32];
    const AMOUNT: u64 = 100;

    fn pk(b: u8) -> Pubkey {
        Pubkey::new_from_array([b; 32])
    }

    // vary only the dynamic fields; from/to/amount/nonce held fixed
    fn h(data: &[u8], extra_data: &[u8]) -> [u8; 32] {
        request_hash(pk(1), pk(2), AMOUNT, NONCE, data, extra_data)
    }

    #[test]
    fn identical_params_hash_equal() {
        assert_eq!(h(&[0x01, 0x02], &[0x03]), h(&[0x01, 0x02], &[0x03]));
        assert_eq!(h(&[], &[]), h(&[], &[]));
    }

    // the ambiguity this encoding exists to prevent: raw concatenation gave these
    // two distinct requests the same preimage
    #[test]
    fn adjacent_dynamic_fields_do_not_collide() {
        assert_ne!(h(&[0x01], &[0x02, 0x03]), h(&[0x01, 0x02], &[0x03]));
    }

    // the same ambiguity at the empty-field boundary
    #[test]
    fn empty_field_boundary_does_not_collide() {
        assert_ne!(h(&[], &[0x01]), h(&[0x01], &[]));
        assert_ne!(h(&[], &[0x01, 0x02]), h(&[0x01, 0x02], &[]));
    }

    #[test]
    fn each_dynamic_field_changes_hash() {
        let base = h(&[0x01], &[0x02]);

        assert_ne!(base, h(&[0x11], &[0x02]), "data content");
        assert_ne!(base, h(&[0x01], &[0x12]), "extra_data content");
        assert_ne!(base, h(&[0x01, 0x01], &[0x02]), "data length");
        assert_ne!(base, h(&[0x01], &[0x02, 0x02]), "extra_data length");
        assert_ne!(base, h(&[], &[0x02]), "data emptied");
        assert_ne!(base, h(&[0x01], &[]), "extra_data emptied");
    }

    #[test]
    fn each_fixed_field_changes_hash() {
        let base = h(&[0x01], &[0x02]);

        assert_ne!(
            base,
            request_hash(pk(9), pk(2), AMOUNT, NONCE, &[0x01], &[0x02]),
            "from"
        );
        assert_ne!(
            base,
            request_hash(pk(1), pk(9), AMOUNT, NONCE, &[0x01], &[0x02]),
            "to"
        );
        assert_ne!(
            base,
            request_hash(pk(1), pk(2), AMOUNT + 1, NONCE, &[0x01], &[0x02]),
            "amount"
        );
        assert_ne!(
            base,
            request_hash(pk(1), pk(2), AMOUNT, [4u8; 32], &[0x01], &[0x02]),
            "nonce"
        );
    }

    // from/to occupy the same width, so swapping them must still change the hash
    #[test]
    fn from_and_to_are_not_interchangeable() {
        assert_ne!(
            request_hash(pk(1), pk(2), AMOUNT, NONCE, &[0x01], &[0x02]),
            request_hash(pk(2), pk(1), AMOUNT, NONCE, &[0x01], &[0x02]),
        );
    }
}
