// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "./MToken.sol";

// this contract will be deployed on L2s for testing purposes where not support cross-chain messaging
contract MTokenSideForTest is MToken {
    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator
    ) public initializer {
        __MTOKEN_init(name, symbol, _owner, _operator);
    }

    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        mintBudget += uint112(mintBudgetDelta);
    }

    function decreaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        mintBudget -= mintBudgetDelta;
    }
}
