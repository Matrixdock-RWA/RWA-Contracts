use anchor_lang::prelude::*;

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

    // delay in seconds
    pub delay: i64,
    pub next_delay: i64,
    pub next_delay_et: i64,

    pub next_mint_recipient: Pubkey,
    pub next_mint_amount: u64,
    pub next_mint_et: i64,
    pub next_mint_nonce: [u8; 32],

    pub mint_budget: u64,

    // reserved for future fields
    pub _reserved: [u8; 256],

    pub bump: u8,
}

impl State {
    pub fn init(&mut self, owner: Pubkey, delay: i64, bump: u8) {
        self.owner = owner;
        self.next_owner = owner;
        self.operator = owner;
        self.next_operator = owner;
        self.revoker = owner;
        self.next_revoker = owner;
        self.messager = owner;
        self.next_messager = owner;
        self.delay = delay;
        self.next_mint_recipient = owner;
        self.next_mint_nonce = [0; 32];
        self.bump = bump;
    }
}
