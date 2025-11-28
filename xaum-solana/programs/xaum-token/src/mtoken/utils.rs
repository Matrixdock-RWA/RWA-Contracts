use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    account_info::AccountInfo, program::invoke, rent::Rent, system_instruction::transfer,
};

pub fn update_account_lamports_to_minimum_rent_balance<'info>(
    account: AccountInfo<'info>,
    payer: AccountInfo<'info>,
    system_program: AccountInfo<'info>,
) -> Result<()> {
    let balance_needed = Rent::get()?.minimum_balance(account.data_len());
    let balance = account.get_lamports();
    if balance_needed > balance {
        invoke(
            &transfer(payer.key, account.key, balance_needed - balance),
            &[payer, account, system_program],
        )?;
    }
    Ok(())
}
