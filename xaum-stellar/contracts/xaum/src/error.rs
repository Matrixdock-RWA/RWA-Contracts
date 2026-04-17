use soroban_sdk::contracterror;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum TokenError {
    // -------- generic --------
    NegativeAmountNotAllowed = 1,

    // -------- auth / role --------
    NotOwner = 10,
    NotOperator = 11,
    NotRevoker = 12,
    NoPendingOwner = 13,

    // -------- delay / timelock --------
    DelayTooSmall = 20,
    TooEarlyToExecute = 21,
    PendingRequestExists = 22,
    DelayTooLarge = 23,

    // -------- mint / budget --------
    MintBudgetNotEnough = 30,

    // -------- block list --------
    UserBlocked = 40,

    // -------- allowance --------
    InsufficientAllowance = 50,
    InvalidExpirationLedger = 51,

    // -------- balance --------
    InsufficientBalance = 60,

    // -------- config --------
    InvalidDecimal = 70,
    InvalidWasmHash = 71,
    NoPendingUpgrade = 72,

    // -------- supply --------
    TotalSupplyUnderflow = 81,

    // -------- unsupported --------
    NotSupported = 90,
}
