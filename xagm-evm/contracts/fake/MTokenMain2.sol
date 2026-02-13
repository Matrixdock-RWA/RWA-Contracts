// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MTokenMain} from "../MTokenMain.sol";

contract MTokenMain2 is MTokenMain {

    function version() public pure returns (uint) {
        return 2;
    }

}