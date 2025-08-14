// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IBullionMinter {
    function requestToMint(address transferredToken, address forToken, uint amount, uint preprice, uint slippage, uint timestamp) external;
}
