// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ICustomerManager {
    function inWhiteList(address _address) external view returns (bool);
}
