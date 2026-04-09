module xagm::xagm;

use mtoken::mtoken;
use sui::url;

const DECIMALS: u8 = 9;
const SYMBOL: vector<u8> = b"XAGM";
const NAME: vector<u8> = b"Matrixdock Silver";
const DESCRIPTION: vector<u8> = b"Matrixdock Silver (XAGm) is a standardized token on blockchains, where 1 token initially represents one fine troy ounce of 99.9% purity LBMA-accredited Good Delivery silver. This representation will decrease slightly over time as custody fees accrue.";
const ICON_URL: vector<u8> = b"https://app.matrixdock.com/images/xagm/xagm-100x100-icon.png";
const ALLOW_GLOBAL_PAUSE: bool = true;
const INIT_DELAY: u64 = 0;

// https://move-book.com/programmability/one-time-witness.html
public struct XAGM has drop {}

// https://move-book.com/programmability/module-initializer.html
fun init(witness: XAGM, ctx: &mut TxContext) {
    let icon_url = option::some(url::new_unsafe_from_bytes(ICON_URL));
    mtoken::create_coin(
        witness,
        DECIMALS,
        SYMBOL,
        NAME,
        DESCRIPTION,
        icon_url,
        ALLOW_GLOBAL_PAUSE,
        INIT_DELAY,
        ctx,
    );
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(XAGM {}, ctx);
}
