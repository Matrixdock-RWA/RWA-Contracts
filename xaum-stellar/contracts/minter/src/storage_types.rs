use soroban_sdk::{contracttype, Address};

pub(crate) const DAY_IN_LEDGERS: u32 = 17280;
pub(crate) const INSTANCE_BUMP_AMOUNT: u32 = 7 * DAY_IN_LEDGERS;
pub(crate) const INSTANCE_LIFETIME_THRESHOLD: u32 = INSTANCE_BUMP_AMOUNT - DAY_IN_LEDGERS;

#[contracttype]
pub enum DataKey {
    Owner,        // Address
    PendingOwner, // Address
    PoolAccountA, // MuxedAddress
    PoolAccountB, // MuxedAddress

    AcceptedByA(Address), // address => bool
    AcceptedByB(Address), // address => bool
}
