use soroban_sdk::{contracttype, Address};

pub(crate) const DAY_IN_LEDGERS: u32 = 17280;
pub(crate) const PENDING_TTL_LEDGERS: u32 = 10 * DAY_IN_LEDGERS; // 10 days, well above MAX_GOV_DELAY (7 days)

pub(crate) const INSTANCE_BUMP_AMOUNT: u32 = 30 * DAY_IN_LEDGERS;
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
    GovDelay,     // u64, governance-level timelock
    NextGovDelay,
    EtNextGovDelay,

    AcceptedByA(Address), // address => bool
    AcceptedByB(Address), // address => bool
}
