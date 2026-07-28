use soroban_sdk::{contracttype, Address, BytesN};

pub(crate) const DAY_IN_LEDGERS: u32 = 17280;
pub(crate) const PENDING_TTL_LEDGERS: u32 = 10 * DAY_IN_LEDGERS; // 10 days, well above MAX_DELAY (7 days)
pub(crate) const MINT_REQUEST_TTL_LEDGERS: u32 = 20 * DAY_IN_LEDGERS; // 20 days for pending mint requests

pub(crate) const INSTANCE_BUMP_AMOUNT: u32 = 30 * DAY_IN_LEDGERS;
pub(crate) const INSTANCE_LIFETIME_THRESHOLD: u32 = INSTANCE_BUMP_AMOUNT - DAY_IN_LEDGERS;

pub(crate) const BALANCE_BUMP_AMOUNT: u32 = 30 * DAY_IN_LEDGERS;
pub(crate) const BALANCE_LIFETIME_THRESHOLD: u32 = BALANCE_BUMP_AMOUNT - DAY_IN_LEDGERS;

pub(crate) const ALLOW_BLOCK_EXTEND_AMOUNT: u32 = 30 * DAY_IN_LEDGERS;
pub(crate) const ALLOW_BLOCK_TTL_THRESHOLD: u32 = ALLOW_BLOCK_EXTEND_AMOUNT - DAY_IN_LEDGERS;

#[derive(Clone)]
#[contracttype]
pub struct AllowanceDataKey {
    pub from: Address,
    pub spender: Address,
}

#[contracttype]
pub struct AllowanceValue {
    pub amount: i128,
    pub expiration_ledger: u32,
}

#[derive(Clone)]
#[contracttype]
pub enum DataKey {
    Allowance(AllowanceDataKey),
    Balance(Address),
    MintRequest(BytesN<32>), // hash(receiver, amount, nonce) -> u64(et)
    ForcedTransferRequest(BytesN<32>), // hash(from, to, amount, nonce, data, extra_data) -> u64(et)
    Blocked(Address),
    NewWasmHash, //BytesN<32>, hash of the new wasm to be set by upgrade
    EtNextUpgrade,
    TotalSupply,
    MintBudget,
    Owner,
    PendingOwner,
    EtNextOwner,
    Delay,
    NextDelay,
    EtNextDelay,
    Operator,
    NextOperator,
    EtNextOperator,
    Revoker,
    NextRevoker,
    EtNextRevoker,
    GovDelay,
    NextGovDelay,
    EtNextGovDelay,
    Paused,
    EtNextUnpause,
    ForcedTransferReceiver,
    NextForcedTransferReceiver,
    EtNextForcedTransferReceiver,
}
