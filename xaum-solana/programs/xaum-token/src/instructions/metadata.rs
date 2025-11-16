use anchor_lang::prelude::*;
use anchor_spl::metadata::{
    mpl_token_metadata::accounts::Metadata as MplMetadata, mpl_token_metadata::types::DataV2,
    update_metadata_accounts_v2, Metadata, UpdateMetadataAccountsV2,
};

use super::super::mtoken::{errors::ErrorCode, state::State};

#[derive(Accounts)]
pub struct UpdateMetadata<'info> {
    pub owner: Signer<'info>,

    #[account(
        seeds = [b"state"],
        bump = state.bump,
        has_one = owner @ ErrorCode::NotOwner,
    )]
    state: Account<'info, State>,

    /// CHECK: Validate address by deriving pda
    #[account(
        seeds = [b"mint"],
        bump,
    )]
    pub mint_account: UncheckedAccount<'info>,

    /// CHECK: Validate address by deriving pda
    #[account(
        mut,
        seeds = [b"metadata", token_metadata_program.key().as_ref(), mint_account.key().as_ref()],
        bump,
        seeds::program = token_metadata_program.key(),
    )]
    pub metadata_account: UncheckedAccount<'info>,

    pub token_metadata_program: Program<'info, Metadata>,
}

pub fn update_metadata(ctx: Context<UpdateMetadata>, uri: String) -> Result<()> {
    // PDA signer seeds
    let signer_seeds: &[&[&[u8]]] = &[&[b"mint", &[ctx.bumps.mint_account]]];

    let new_data: DataV2;
    {
        let data = ctx.accounts.metadata_account.data.try_borrow_mut().unwrap();
        let metadata_acc = MplMetadata::deserialize(&mut data.as_ref())?;
        new_data = DataV2 {
            name: metadata_acc.name,
            symbol: metadata_acc.symbol,
            uri: uri,
            seller_fee_basis_points: metadata_acc.seller_fee_basis_points,
            creators: metadata_acc.creators,
            collection: metadata_acc.collection,
            uses: metadata_acc.uses,
        };
    }

    update_metadata_accounts_v2(
        CpiContext::new(
            ctx.accounts.token_metadata_program.to_account_info(),
            UpdateMetadataAccountsV2 {
                metadata: ctx.accounts.metadata_account.to_account_info(),
                update_authority: ctx.accounts.mint_account.to_account_info(),
            },
        )
        .with_signer(signer_seeds),
        None,
        Some(new_data), // data
        None,           // primary_sale_happened
        None,           // is_mutable
    )?;
    Ok(())
}
