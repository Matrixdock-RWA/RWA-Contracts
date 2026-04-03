use soroban_sdk::contracterror;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum TokenError {
    // -------- generic --------
    NegativeAmountNotAllowed = 1,
    MathOverflow = 2,

    // -------- auth / role --------
    NotOwner = 10,
    NotOperator = 11,
    NotRevoker = 12,
    NoPendingOwner = 13,

    // -------- delay / timelock --------
    DelayTooSmall = 20,
    TooEarlyToExecute = 21,
    PendingRequestExists = 22,

    // -------- mint / budget --------
    MintBudgetNotEnough = 30,
    MintBudgetOverflow = 31,

    // -------- block list --------
    UserBlocked = 40,

    // -------- allowance --------
    InsufficientAllowance = 50,
    InvalidExpirationLedger = 51,

    // -------- balance --------
    InsufficientBalance = 60,

    // -------- config --------
    InvalidDecimal = 70,

    // -------- supply --------
    TotalSupplyOverflow = 80,
    TotalSupplyUnderflow = 81,

    // -------- unsupported --------
    NotSupported = 90,
}
