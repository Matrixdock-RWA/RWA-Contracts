PKG_IDR=$PWD/packages

echo '===== build mtoken ====='
cd $PKG_IDR/mtoken
sui move build

echo '===== build xagm ====='
cd $PKG_IDR/xagm
sui move build

echo '===== build messenger_lz ====='
cd $PKG_IDR/messenger_lz
sui move build

echo '===== build minter ====='
cd $PKG_IDR/minter
sui move build
