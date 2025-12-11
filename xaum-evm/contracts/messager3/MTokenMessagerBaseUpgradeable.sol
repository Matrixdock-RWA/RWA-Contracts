// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {DelayedUpgradeable} from "../DelayedUpgradeable.sol";

abstract contract MTokenMessagerBaseUpgradeable is DelayedUpgradeable {
    uint64 constant MIN_DELAY = 1 hours;

    address public ccClient;

    uint64 public delay;
    uint64 public nextDelay;
    uint64 public etNextDelay; // effective time

    event SetDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetDelayEffected(uint64 newDelay);
    error DelayTooSmall();

    function __MTokenMessagerBase_init(
        address _ccClient,
        address _initialOwner
    ) internal onlyInitializing {
        __Ownable_init(_initialOwner);
        ccClient = _ccClient;
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function setDelay(uint64 _delay) public onlyOwner {
        if (_delay < MIN_DELAY) {
            revert DelayTooSmall();
        }

        uint64 et = etNextDelay;
        if (_delay == nextDelay && et != 0 && et < block.timestamp) {
            delay = _delay;
            emit SetDelayEffected(_delay);
        } else {
            nextDelay = _delay;
            etNextDelay = uint64(block.timestamp) + delay;
            emit SetDelayRequest(delay, _delay, etNextDelay);
        }
    }

    function revokeNextUpgrade() public onlyOwner {
        etNextUpgradeToAndCall = 0;
    }
}
