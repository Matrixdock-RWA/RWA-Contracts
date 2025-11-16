#![allow(clippy::result_large_err)]

pub mod instructions;
pub mod mtoken;

use anchor_lang::prelude::*;
use instructions::*;

declare_id!("F6DjYVsndrWQayFnRvDpgCVmgCFqLempxxCmATbKjcoi");

#[program]
pub mod xaum_token {
    use super::*;

    pub fn create_token(
        ctx: Context<CreateToken>,
        token_name: String,
        token_symbol: String,
        token_uri: String,
        delay: i64, // Delay in seconds
    ) -> Result<()> {
        create::create_token(ctx, token_name, token_symbol, token_uri, delay)
    }

    pub fn mint_token(ctx: Context<MintToken>, amount: u64, nonce: [u8; 32]) -> Result<()> {
        mint::mint_token(ctx, amount, nonce)
    }

    pub fn revoke_mint(ctx: Context<RevokerOp>) -> Result<()> {
        authority::revoke_mint(ctx)
    }

    pub fn change_mint_budget(ctx: Context<OperatorOp>, delta: i64) -> Result<()> {
        authority::change_mint_budget(ctx, delta)
    }

    pub fn redeem_token(
        ctx: Context<RedeemToken>,
        amount: u64,
        customer: Pubkey,
        data: Vec<u8>,
    ) -> Result<()> {
        redeem::redeem_token(ctx, amount, customer, data)
    }

    pub fn add_to_blocked_list(ctx: Context<Freeze>) -> Result<()> {
        freeze::freeze(ctx)
    }

    pub fn remove_from_blocked_list(ctx: Context<Thaw>) -> Result<()> {
        thaw::thaw(ctx)
    }

    pub fn transfer_ownership(ctx: Context<OwnerOp>, new_owner: Pubkey) -> Result<()> {
        authority::transfer_ownership(ctx, new_owner)
    }

    pub fn revoke_next_owner(ctx: Context<OwnerOp>) -> Result<()> {
        authority::revoke_next_owner(ctx)
    }

    pub fn set_operator(ctx: Context<OwnerOp>, new_operator: Pubkey) -> Result<()> {
        authority::set_operator(ctx, new_operator)
    }

    pub fn revoke_next_operator(ctx: Context<RevokerOp>) -> Result<()> {
        authority::revoke_next_operator(ctx)
    }

    pub fn set_revoker(ctx: Context<OwnerOp>, new_revoker: Pubkey) -> Result<()> {
        authority::set_revoker(ctx, new_revoker)
    }

    pub fn revoke_next_revoker(ctx: Context<OwnerOp>) -> Result<()> {
        authority::revoke_next_revoker(ctx)
    }

    pub fn set_messager(ctx: Context<OwnerOp>, new_messager: Pubkey) -> Result<()> {
        authority::set_messager(ctx, new_messager)
    }

    pub fn revoke_next_messager(ctx: Context<RevokerOp>) -> Result<()> {
        authority::revoke_next_messager(ctx)
    }

    pub fn set_delay(ctx: Context<OwnerOp>, new_delay: i64) -> Result<()> {
        authority::set_delay(ctx, new_delay)
    }

    pub fn revoke_next_delay(ctx: Context<RevokerOp>) -> Result<()> {
        authority::revoke_next_delay(ctx)
    }

    pub fn update_metadata(ctx: Context<UpdateMetadata>, uri: String) -> Result<()> {
        metadata::update_metadata(ctx, uri)
    }
}
