PKG_IDR=$PWD/packages

echo '===== test mtoken ====='
cd $PKG_IDR/mtoken
sui move test

echo '===== test xagm ====='
cd $PKG_IDR/xagm
sui move test

echo '===== test messenger_lz ====='
cd $PKG_IDR/messenger_lz
sui move test

echo '===== test minter ====='
cd $PKG_IDR/minter
sui move test
