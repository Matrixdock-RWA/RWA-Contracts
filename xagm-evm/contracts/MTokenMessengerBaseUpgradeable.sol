// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";

abstract contract MTokenMessengerBaseUpgradeable is DelayedUpgradeable {
    address public ccClient;

    uint64 public delay;
    uint64 private __nextDelay;   // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextDelay; // dead slot — preserved for upgradeable storage layout

    function __MTokenMessengerBase_init(
        address _ccClient,
        address _initialOwner
    ) internal onlyInitializing {
        __Ownable_init(_initialOwner);
        __TimeLockerUpgradeable_init();
        ccClient = _ccClient;
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function setDelay(uint64 _delay) public onlyOwner {
        checkDelay(_delay);
        uint64 et = ensureDelay(OP_SET_DELAY, _delay, delay);
        if (et == 0) {
            delay = _delay;
            emit SetDelayEffected(_delay);
        } else {
            emit SetDelayRequest(delay, _delay, et);
        }
    }

}
