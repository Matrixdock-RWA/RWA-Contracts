use anchor_lang::prelude::*;

// UPGRADE SAFETY: This struct is Borsh-serialized in declaration order.
// New fields (gov_delay group) are carved from the head of _reserved,
// which was zero-initialized on existing mainnet accounts. All-zero decodes to valid
// initial state (gov_delay=0 = no timelock until set).
// _reserved was 256 bytes; 24 bytes were consumed; it is now 232 bytes.
// Total INIT_SPACE is unchanged — no account reallocation required on upgrade.
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

    // operational delay: operator / revoker / messager / mint changes (1h–7d)
    pub delay: i64,
    pub next_delay: i64,
    pub next_delay_et: i64,

    pub next_mint_recipient: Pubkey,
    pub next_mint_amount: u64,
    pub next_mint_et: i64,
    pub next_mint_nonce: [u8; 32],

    pub mint_budget: u64,

    // governance delay: ownership transfer (1h–7d).
    // Carved from _reserved head; existing accounts read zero → gov_delay=0 until set.
    pub gov_delay: i64,
    pub next_gov_delay: i64,
    pub next_gov_delay_et: i64,

    // reserved for future fields (256 - 24 consumed above = 232 remaining)
    pub _reserved: [u8; 232],

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
        self.bump = bump;
    }
}
