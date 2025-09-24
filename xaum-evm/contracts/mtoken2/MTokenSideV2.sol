// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./MToken.sol";

// this contract will be deployed on L2s
contract MTokenSide is MToken {
    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator
    ) public initializer {
        __MTOKEN_init(name, symbol, _owner, _operator);
    }
}
