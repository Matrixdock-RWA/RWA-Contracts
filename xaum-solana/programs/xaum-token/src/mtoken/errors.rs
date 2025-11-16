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
}
