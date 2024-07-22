// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

interface IMToken {
    function pack(address tokenOwner, uint amount) external;
    function unpack(address tokenOwner, uint amount) external;
    function mintTo(
        address receiver,
        uint amount,
        uint nonce
    ) external returns (bool);
    function redeem(uint amount, address customer, bytes memory data) external;
    function operator() external returns (address);
    function revoker() external returns (address);
    function isBlocked(address addr) external returns (bool);
    function delay() external returns (uint64);
}
