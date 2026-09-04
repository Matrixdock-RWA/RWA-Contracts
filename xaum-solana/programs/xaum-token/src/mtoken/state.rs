use anchor_lang::prelude::*;

// UPGRADE SAFETY: This struct is Borsh-serialized in declaration order.
// New fields are carved from the head of _reserved, which was zero-initialized
// on existing mainnet accounts. All-zero decodes to valid initial state.
// _reserved was 256 bytes; 24 bytes consumed by gov_delay group, then 72 bytes by
// forced_transfer_receiver group = 160 remaining.
// next_forced_transfer_et/next_forced_transfer_hash and next_unpause_et have not
// shipped to mainnet, so they carry no legacy layout to preserve and were declared
// (and reordered) freely: 40 bytes for the forced-transfer pair (et + hash), then 8
// bytes for next_unpause_et = 112 remaining. The mint-budget relay consumes 92 more
// bytes, leaving 20. Total INIT_SPACE is unchanged — no
// account reallocation required on upgrade.
#[account]
#[derive(InitSpace)]
pub struct State {
    // owner authority
    pub owner: Pubkey,
    pub next_owner: Pubkey,
    pub next_owner_et: i64,

    // operator authority
    pub operator: Pubkey,
    pub next_operator: Pubkey,
    pub next_operator_et: i64,

    // revoker authority
    pub revoker: Pubkey,
    pub next_revoker: Pubkey,
    pub next_revoker_et: i64,

    // messager authority
    pub messager: Pubkey,
    pub next_messager: Pubkey,
    pub next_messager_et: i64,

    // operational delay: operator / mint / forceTransfer / unpause changes (1h–48h).
    // revoker & messager were promoted to gov_delay in Timelock V2.
    pub delay: i64,
    pub next_delay: i64,
    pub next_delay_et: i64,

    pub next_mint_recipient: Pubkey,
    pub next_mint_amount: u64,
    pub next_mint_et: i64,
    pub next_mint_nonce: [u8; 32],

    pub mint_budget: u64,

    // governance delay: owner / revoker / messager / setDelay / setGovDelay /
    // forcedTransferReceiver changes (24h–7d).
    // Carved from _reserved head; existing accounts read zero → gov_delay=0 until set.
    pub gov_delay: i64,
    pub next_gov_delay: i64,
    pub next_gov_delay_et: i64,

    // forced transfer receiver: whitelisted to-address for forced transfers.
    // Carved from _reserved head; zero → no receiver until explicitly set.
    pub forced_transfer_receiver: Pubkey,
    pub next_forced_transfer_receiver: Pubkey,
    pub next_forced_transfer_receiver_et: i64,

    // pending forced transfer — single-slot two-call pattern (mirrors mint).
    // Request identity (from/to/amount/nonce/data/extra_data) is captured entirely by
    // next_forced_transfer_hash (mirrors EVM's reqHash); next_forced_transfer_et only
    // holds the delay expiry, since it's compared against the clock directly. This
    // feature has not shipped to mainnet, so there's no legacy from/to/amount/nonce
    // layout to preserve.
    pub next_forced_transfer_et: i64,
    pub next_forced_transfer_hash: [u8; 32],

    // pending GlobalUnpause — single-slot delayed op (#14). 0 = none pending.
    // Not shipped to mainnet either, so it was declared after the forced-transfer pair
    // above to keep next_forced_transfer_et and next_forced_transfer_hash adjacent.
    pub next_unpause_et: i64,

    // In-house mint-budget relay. All fields are carved from the old zero-filled
    // reserve, so an existing account upgrades with the feature disabled until the
    // owner configures submitter and local_eid.
    pub mint_budget_submitter: Pubkey,
    pub next_mint_budget_submitter: Pubkey,
    pub next_mint_budget_submitter_et: i64,
    pub mint_budget_total_allocated_amount: u64,
    pub mint_budget_total_returned_amount: u64,
    pub local_eid: u32,

    // reserved for future fields (running total, in declaration order above)
    // 256 - 24 consumed by gov_delay group = 232 remaining
    // 232 - 72 consumed by forced_transfer_receiver group = 160 remaining
    // 160 - 40 consumed by next_forced_transfer_et (8) + next_forced_transfer_hash (32) = 120 remaining
    // 120 - 8 consumed by next_unpause_et = 112 remaining
    // 112 - 92 consumed by mint-budget relay fields = 20 remaining
    pub _reserved: [u8; 20],

    pub bump: u8,
}

impl State {
    pub fn init(&mut self, owner: Pubkey, delay: i64, gov_delay: i64, bump: u8) {
        self.owner = owner;
        self.next_owner = owner;
        self.operator = owner;
        self.next_operator = owner;
        self.revoker = owner;
        self.next_revoker = owner;
        self.messager = owner;
        self.next_messager = owner;
        self.delay = delay;
        self.gov_delay = gov_delay;
        self.next_mint_recipient = owner;
        self.next_mint_nonce = [0; 32];
        self.mint_budget_submitter = Pubkey::default();
        self.next_mint_budget_submitter = Pubkey::default();
        self.next_mint_budget_submitter_et = 0;
        self.mint_budget_total_allocated_amount = 0;
        self.mint_budget_total_returned_amount = 0;
        self.local_eid = 0;
        self.bump = bump;
    }
}
