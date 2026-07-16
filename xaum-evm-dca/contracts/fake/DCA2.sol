// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "../XAUMDCA.sol";

contract DCA2 is XAUMDCA {
    function version() public pure returns (uint) {
        return 2;
    }
}
