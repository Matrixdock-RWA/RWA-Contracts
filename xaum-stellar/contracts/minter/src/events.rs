use soroban_sdk::{contractevent, Address, Bytes, BytesN};

#[contractevent]
pub struct OwnerTransferRequested {
    pub owner: Address,
    pub pending_owner: Address,
    pub effective_time: u64,
}

#[contractevent]
pub struct OwnerTransferred {
    pub old_owner: Address,
    pub new_owner: Address,
}

#[contractevent]
pub struct SetPoolAccountA {
    pub pool: Address,
}

#[contractevent]
pub struct SetPoolAccountB {
    pub pool: Address,
}

#[contractevent]
pub struct SetAcceptedByA {
    #[topic]
    pub token: Address,
    pub accepted: bool,
}

#[contractevent]
pub struct SetAcceptedByB {
    #[topic]
    pub token: Address,
    pub accepted: bool,
}

#[contractevent]
pub struct MintRequest {
    #[topic]
    pub transferred_token: Address,
    #[topic]
    pub for_token: Address,
    #[topic]
    pub requestor: Address,
    pub pool: Address,
    pub amount: i128,
    pub preprice: u128,
    pub slippage: u128,
    pub extra_data: Bytes,
}

#[contractevent]
pub struct RedeemRequest {
    #[topic]
    pub transferred_token: Address,
    #[topic]
    pub for_token: Address,
    #[topic]
    pub requestor: Address,
    pub pool: Address,
    pub amount: i128,
    pub preprice: u128,
    pub slippage: u128,
    pub extra_data: Bytes,
}

#[contractevent]
pub struct UpgradeRequested {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
    pub effective_time: u64,
}

#[contractevent]
pub struct ContractUpgraded {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
}

#[contractevent]
pub struct UpgradeRevoked {
    pub owner: Address,
    pub new_wasm_hash: BytesN<32>,
}
