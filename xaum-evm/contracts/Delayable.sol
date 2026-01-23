// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";

abstract contract Delayable is DelayedUpgradeable {
    uint64 constant MIN_DELAY = 1 hours;

    uint64 public delay;
    uint64 public nextDelay;
    uint64 public etNextDelay;

    address public revoker;
    address public nextRevoker;
    uint64 public etNextRevoker;

    address public operator;
    address public nextOperator;
    uint64 public etNextOperator;

    event SetDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetDelayEffected(uint64 newDelay);
    event SetRevokerRequest(address oldAddr, address newAddr, uint64 et);
    event SetRevokerEffected(address newAddr);
    event SetOperatorRequest(address oldAddr, address newAddr, uint64 et);
    event SetOperatorEffected(address newAddr);

    error NotRevoker(address);
    error NotOperator(address);
    error DelayTooSmall();

    modifier onlyRevoker() {
        if (msg.sender != revoker) {
            revert NotRevoker(msg.sender);
        }
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) {
            revert NotOperator(msg.sender);
        }
        _;
    }

    function __Delayable_init(
        address _owner,
        address _operator,
        address _revoker
    ) internal onlyInitializing {
        __Ownable_init(_owner);
        operator = _operator;
        revoker = _revoker;
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function revokeNextUpgrade() public onlyRevoker {
        etNextUpgradeToAndCall = 0;
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
            uint64 _currDelay = delay;
            uint64 _etNextDelay = uint64(block.timestamp) + _currDelay;
            nextDelay = _delay;
            etNextDelay = _etNextDelay;
            emit SetDelayRequest(_currDelay, _delay, _etNextDelay);
        }
    }

    function revokeNextDelay() public onlyRevoker {
        etNextDelay = 0;
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        uint64 et = etNextRevoker;
        if (_revoker == nextRevoker && et != 0 && et < block.timestamp) {
            revoker = _revoker;
            emit SetRevokerEffected(_revoker);
        } else {
            nextRevoker = _revoker;
            uint64 _etNextRevoker = uint64(block.timestamp) + delay;
            etNextRevoker = _etNextRevoker;
            emit SetRevokerRequest(revoker, _revoker, _etNextRevoker);
        }
    }

    function revokeNextRevoker() public onlyOwner {
        etNextRevoker = 0;
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        uint64 et = etNextOperator;
        if (_operator == nextOperator && et != 0 && et < block.timestamp) {
            operator = _operator;
            emit SetOperatorEffected(_operator);
        } else {
            nextOperator = _operator;
            uint64 _etNextOperator = uint64(block.timestamp) + delay;
            etNextOperator = _etNextOperator;
            emit SetOperatorRequest(operator, _operator, _etNextOperator);
        }
    }

    function revokeNextOperator() public onlyRevoker {
        etNextOperator = 0;
    }
}
