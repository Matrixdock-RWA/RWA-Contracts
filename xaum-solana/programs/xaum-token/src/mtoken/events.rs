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
pub struct RevokeNextOwner {
    pub pending_owner: Pubkey,
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
pub struct RevokeNextOperator {
    pub pending_operator: Pubkey,
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
pub struct RevokeNextRevoker {
    pub pending_revoker: Pubkey,
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
pub struct RevokeNextMessager {
    pub pending_messager: Pubkey,
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
pub struct RevokeNextDelay {
    pub pending_delay: i64,
}

#[event]
pub struct SetGovDelayRequest {
    pub old_delay: i64,
    pub new_delay: i64,
    pub et: i64,
}

#[event]
pub struct SetGovDelayEffected {
    pub new_delay: i64,
}

#[event]
pub struct RevokeNextGovDelay {
    pub pending_gov_delay: i64,
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
pub struct RevokeNextMint {
    pub pending_mint_nonce: [u8; 32],
}

#[event]
pub struct Redeem {
    pub customer: Pubkey,
    pub amount: u64,
    pub data: Vec<u8>,
}

#[event]
pub struct SetMintBudgetSubmitterRequest {
    pub old_mint_budget_submitter: Pubkey,
    pub new_mint_budget_submitter: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetMintBudgetSubmitterEffected {
    pub new_mint_budget_submitter: Pubkey,
}

#[event]
pub struct RevokeNextMintBudgetSubmitter {
    pub pending_mint_budget_submitter: Pubkey,
}

#[event]
pub struct SetLocalEid {
    pub local_eid: u32,
}

#[event]
pub struct ClaimMintBudgetFromEth {
    pub caller: Pubkey,
    pub dst_eid: u32,
    pub delta_amount: u64,
    pub total_allocated_amount: u64,
    pub src_tx_hash: [u8; 32],
}

#[event]
pub struct ReturnMintBudgetToEth {
    pub caller: Pubkey,
    pub local_eid: u32,
    pub delta_amount: u64,
    pub total_returned_amount: u64,
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
pub struct SetForcedTransferReceiverRequest {
    pub old_receiver: Pubkey,
    pub new_receiver: Pubkey,
    pub et: i64,
}

#[event]
pub struct SetForcedTransferReceiverEffected {
    pub new_receiver: Pubkey,
}

#[event]
pub struct RevokeNextForcedTransferReceiver {
    pub pending_receiver: Pubkey,
}

#[event]
pub struct ForcedTransferRequest {
    pub from: Pubkey,
    pub to: Pubkey,
    pub amount: u64,
    pub data: Vec<u8>,
    pub extra_data: Vec<u8>,
}

#[event]
pub struct RevokeForcedTransfer {
    pub hash: [u8; 32],
}

#[event]
pub struct ForceTransfer {
    pub from: Pubkey,
    pub to: Pubkey,
    pub amount: u64,
    pub data: Vec<u8>,
    pub extra_data: Vec<u8>,
}

#[event]
pub struct Paused {
    pub caller: Pubkey,
}

// #14: request to unpause (delayed). Effected by the `Unpaused` event.
#[event]
pub struct UnpauseRequest {
    pub et: i64,
}

#[event]
pub struct Unpaused {
    pub caller: Pubkey,
}

#[event]
pub struct RevokeNextUnpause {
    pub pending_et: i64,
}
