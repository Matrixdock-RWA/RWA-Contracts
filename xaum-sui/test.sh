PKG_IDR=$PWD/packages

echo '===== test mtoken ====='
cd $PKG_IDR/mtoken
sui move test

echo '===== test xaum ====='
cd $PKG_IDR/xaum
sui move test

echo '===== test minter ====='
cd $PKG_IDR/minter
sui move test

echo '===== test messenger_lz ====='
cd $PKG_IDR/messenger_lz
sui move test
