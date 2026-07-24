pub const XAUM_DECIMALS: u8 = 9;

// Two-tier delay bounds (Timelock & Revoke V2). The operational delay and the
// governance delay use INDEPENDENT min/max constants:
//   - delay (operational: operator / mint / forceTransfer / unpause): 1h – 48h
//   - gov_delay (governance: owner / revoker / messager / setDelay / setGovDelay /
//     forcedTransferReceiver): 24h – 7d
// Invariant enforced by both setters: gov_delay >= delay.
pub const MIN_DELAY: i64 = 3600; // 1 hour
pub const MAX_DELAY: i64 = 48 * 3600; // 48 hours

pub const MIN_GOV_DELAY: i64 = 24 * 3600; // 24 hours
pub const MAX_GOV_DELAY: i64 = 7 * 24 * 3600; // 7 days
