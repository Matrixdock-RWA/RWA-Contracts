// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./MTokenV2.sol";

// this contract will be deployed on L2s
contract MTokenSideV2 is MTokenV2 {
    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator
    ) public initializer {
        __MTOKEN_init(name, symbol, _owner, _operator);
    }
}
