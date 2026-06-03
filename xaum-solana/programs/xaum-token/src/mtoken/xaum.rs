pub const XAUM_DECIMALS: u8 = 9;

// Both operational delay (operator/messager/mint) and governance delay (ownership)
// share the same bounds: 1 hour minimum, 7 days maximum.
pub const MIN_ACCEPTABLE_DELAY: i64 = 3600;          // 1 hour
pub const MAX_ACCEPTABLE_DELAY: i64 = 7 * 24 * 3600; // 7 days
