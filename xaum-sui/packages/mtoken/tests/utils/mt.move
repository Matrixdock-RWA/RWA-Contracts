#[test_only]
module mtoken::mt;

use mtoken::mtoken;

// coin metadata
const DECIMALS: u8 = 9;
const SYMBOL: vector<u8> = b"MTokenSymbol";
const NAME: vector<u8> = b"MTokenName";
const DESCRIPTION: vector<u8> = b"MTokenDescription";

public struct MT has drop {}

public fun init_for_testing(ctx: &mut TxContext, init_delay: u64, init_gov_delay: u64) {
    mtoken::create_coin(
        MT {}, // OTW
        DECIMALS,
        SYMBOL,
        NAME,
        DESCRIPTION,
        option::none(),
        true,
        init_delay,
        init_gov_delay,
        ctx,
    );
}

public fun metadata(): (u8, vector<u8>, vector<u8>, vector<u8>) {
    (DECIMALS, SYMBOL, NAME, DESCRIPTION)
}
