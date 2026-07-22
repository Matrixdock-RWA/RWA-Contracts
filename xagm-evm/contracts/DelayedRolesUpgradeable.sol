// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";

abstract contract DelayedRolesUpgradeable is DelayedUpgradeable {
    uint64 public delay;
    uint64 private __nextDelay;   // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextDelay; // dead slot — preserved for upgradeable storage layout

    address public revoker;
    address private __nextRevoker;   // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextRevoker;  // dead slot — preserved for upgradeable storage layout

    address public operator;
    address private __nextOperator;  // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextOperator; // dead slot — preserved for upgradeable storage layout

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

    function __DelayedRolesUpgradeable_init(
        address _owner,
        address _operator,
        address _revoker
    ) internal onlyInitializing {
        __Ownable_init(_owner);
        __TimeLockerUpgradeable_init_unchained();
        operator = _operator;
        revoker = _revoker;
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function revokeNextUpgrade() public override onlyRevoker {
        _revokeNextUpgrade();
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

    function revokeNextDelay() public onlyRevoker {
        revoke(OP_SET_DELAY);
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        uint64 et = ensureGovDelay(OP_SET_REVOKER, uint160(_revoker));
        if (et == 0) {
            revert NotNewRevoker(msg.sender);
        }
        emit SetRevokerRequest(revoker, _revoker, et);
    }

    function acceptRevoker() public {
        address newRevoker = msg.sender;
        uint64 et = ensureGovDelay(OP_SET_REVOKER, uint160(newRevoker));
        if (et > 0) {
            revert NoPendingRequest(OP_SET_REVOKER);
        }
        revoker = newRevoker;
        emit SetRevokerEffected(newRevoker);
    }

    function revokeNextRevoker() public onlyOwner {
        revoke(OP_SET_REVOKER);
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        uint64 et = ensureDelay(OP_SET_OPERATOR, uint160(_operator), delay);
        if (et == 0) {
            operator = _operator;
            emit SetOperatorEffected(_operator);
        } else {
            emit SetOperatorRequest(operator, _operator, et);
        }
    }

    function revokeNextOperator() public onlyRevoker {
        revoke(OP_SET_OPERATOR);
    }
}
