use soroban_sdk::{contracttype, Address};

pub(crate) const DAY_IN_LEDGERS: u32 = 17280;
pub(crate) const PENDING_TTL_LEDGERS: u32 = 3 * DAY_IN_LEDGERS; // 3 days, well above DELAY_SETTING (12 hours)
pub(crate) const INSTANCE_BUMP_AMOUNT: u32 = 7 * DAY_IN_LEDGERS;
pub(crate) const INSTANCE_LIFETIME_THRESHOLD: u32 = INSTANCE_BUMP_AMOUNT - DAY_IN_LEDGERS;

#[contracttype]
pub enum DataKey {
    Owner,        // Address
    PendingOwner, // Address
    EtNextOwner,
    PoolAccountA, // Address
    PoolAccountB, // Address
    NewWasmHash,  //BytesN<32>, hash of the new wasm to be set by upgrade
    EtNextUpgrade,

    AcceptedByA(Address), // address => bool
    AcceptedByB(Address), // address => bool
}
