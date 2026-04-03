use soroban_sdk::contracterror;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum BullionMinterError {
    // -------- amount --------
    NegativeAmountNotAllowed = 1,

    // -------- auth / role --------
    NoPendingOwner = 10,

    // -------- token validation --------
    InvalidTokenForMinting = 20,
    InvalidTokenForRedeeming = 21,
    InvalidForToken = 22,

    // -------- timing --------
    InvalidTimestamp = 30,
}
