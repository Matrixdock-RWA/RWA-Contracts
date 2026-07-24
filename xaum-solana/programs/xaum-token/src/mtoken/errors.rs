use anchor_lang::prelude::*;

#[error_code]
pub enum ErrorCode {
    #[msg("NotOwner")]
    NotOwner,

    #[msg("NotOperator")]
    NotOperator,

    #[msg("NotRevoker")]
    NotRevoker,

    #[msg("NotMessager")]
    NotMessager,

    #[msg("NotEffective")]
    NotEffective,

    #[msg("DelayBelowMinimum")]
    DelayBelowMinimum,

    #[msg("DelayExceedsMaximum")]
    DelayExceedsMaximum,

    #[msg("IncorrectMintInfo")]
    IncorrectMintInfo,

    #[msg("MintBudgetNotEnough")]
    MintBudgetNotEnough,

    #[msg("RequestMismatch")]
    RequestMismatch,

    #[msg("InvalidATA")]
    InvalidATA,

    #[msg("TokenBalanceZero")]
    TokenBalanceZero,

    #[msg("NegativeDelay")]
    NegativeDelay,

    #[msg("NotNextOwner")]
    NotNextOwner,

    #[msg("PendingOwnerExist")]
    PendingOwnerExist,

    #[msg("NoPendingOwner")]
    NoPendingOwner,

    #[msg("NotBlocked")]
    NotBlocked,

    #[msg("InvalidForcedTransferReceiver")]
    InvalidForcedTransferReceiver,

    #[msg("TooEarlyToForcedTransfer")]
    TooEarlyToForcedTransfer,

    #[msg("TransferWouldDrainAccount")]
    TransferWouldDrainAccount,

    #[msg("NotOwnerOrRevoker")]
    NotOwnerOrRevoker,

    #[msg("NotOwnerOrOperator")]
    NotOwnerOrOperator,

    #[msg("NotNextRevoker")]
    NotNextRevoker,

    #[msg("PendingRevokerExist")]
    PendingRevokerExist,

    #[msg("NoPendingRevoker")]
    NoPendingRevoker,

    #[msg("DelayExceedsGovDelay")]
    DelayExceedsGovDelay,

    #[msg("GovDelayBelowDelay")]
    GovDelayBelowDelay,

    #[msg("NotPaused")]
    NotPaused,
}
