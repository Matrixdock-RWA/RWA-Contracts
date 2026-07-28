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
    Unauthorized = 14, // caller is neither of the accepted roles (owner-or-revoker / owner-or-operator)
    NoPendingRevoker = 15,

    // -------- delay / timelock --------
    DelayTooSmall = 20,
    TooEarlyToExecute = 21,
    PendingRequestExists = 22,
    DelayTooLarge = 23,
    GovDelayTooSmall = 24,
    GovDelayTooLarge = 25,
    GovDelayBelowDelay = 26,  // newGovDelay < delay
    DelayExceedsGovDelay = 27, // newDelay > govDelay

    // -------- mint / budget --------
    MintBudgetNotEnough = 30,

    // -------- block list --------
    UserBlocked = 40,
    NotBlocked = 41, // forcedTransfer source must be blocked first

    // -------- forced transfer --------
    InvalidForcedTransferReceiver = 45,
    NoForcedTransferReceiver = 46,

    // -------- pause --------
    ContractPaused = 47,
    NoPendingUnpause = 48,
    NotPaused = 49,

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
