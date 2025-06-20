// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

contract MTokenMessagerBase {

    address public immutable ccClient;

    constructor(address _ccClient){
        ccClient = _ccClient;
    }
}
