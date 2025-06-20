# XAUM-Tron

XAUm on Tron.

All files are identical to the XAUM EVM version, with the sole exception being `ProxyERC1967.sol`. This file wraps the `ERC1967Proxy` contract to facilitate deployment via TronBox. Additionally, the Solidity compiler version used here is 0.8.23, whereas the EVM version employs 0.8.24.
