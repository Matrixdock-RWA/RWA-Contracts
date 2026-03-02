module xagm::xagm;

use mtoken::mtoken;
use sui::url;

const DECIMALS: u8 = 9;
const SYMBOL: vector<u8> = b"XAGm";
const NAME: vector<u8> = b"Matrixdock Silver";
const DESCRIPTION: vector<u8> = b"Matrixdock Silver (XAGm) is ..."; // TODO
const ICON_URL: vector<u8> = b"https://app.matrixdock.com/images/xagm/xagm-64x64-icon.png";
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
