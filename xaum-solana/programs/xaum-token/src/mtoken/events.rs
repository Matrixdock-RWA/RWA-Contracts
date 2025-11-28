use anchor_lang::prelude::*;

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
pub struct SetOperatorRequest {
    pub old_operator: Pubkey,
    pub new_operator: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetOperatorEffected {
    pub new_operator: Pubkey,
}

#[event]
pub struct SetRevokerRequest {
    pub old_revoker: Pubkey,
    pub new_revoker: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetRevokerEffected {
    pub new_revoker: Pubkey,
}

#[event]
pub struct SetMessagerRequest {
    pub old_messager: Pubkey,
    pub new_messager: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetMessagerEffected {
    pub new_messager: Pubkey,
}

#[event]
pub struct SetDelayRequest {
    pub old_delay: i64,
    pub new_delay: i64,
    pub et: i64,
}

#[event]
pub struct SetDelayEffected {
    pub new_delay: i64,
}

#[event]
pub struct MintRequest {
    pub recipient: Pubkey,
    pub amount: u64,
    pub nonce: [u8; 32],
    pub et: i64,
}

#[event]
pub struct MintEffected {
    pub recipient: Pubkey,
    pub amount: u64,
    pub nonce: [u8; 32],
}

#[event]
pub struct Redeem {
    pub customer: Pubkey,
    pub amount: u64,
    pub data: Vec<u8>,
}

#[event]
pub struct ChangeMintBudget {
    pub delta: i64,
}

#[event]
pub struct BlockPlaced {
    pub user: Pubkey,
}

#[event]
pub struct BlockReleased {
    pub user: Pubkey,
}

#[event]
pub struct ForceTransfer {
    pub from: Pubkey,
    pub to: Pubkey,
    pub amount: u64,
}
