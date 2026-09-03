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
        if (ensureDelay(OP_SET_DELAY, delay, _delay, delay)) {
            delay = _delay;
        }
    }

    function revokeNextDelay() public onlyRevoker {
        revoke(OP_SET_DELAY);
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        if (ensureGovDelay(OP_SET_REVOKER, uint160(revoker), uint160(_revoker))) {
            revert NotNewRevoker(msg.sender);
        }
    }

    function acceptRevoker() public {
        address newRevoker = msg.sender;
        if (ensureGovDelay(OP_SET_REVOKER, uint160(revoker), uint160(newRevoker))) {
            revoker = newRevoker;
        } else {
            revert NoPendingRequest(OP_SET_REVOKER);
        }
    }

    function revokeNextRevoker() public onlyOwner {
        revoke(OP_SET_REVOKER);
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        if (ensureDelay(OP_SET_OPERATOR, uint160(operator), uint160(_operator), delay)) {
            operator = _operator;
        }
    }

    function revokeNextOperator() public onlyRevoker {
        revoke(OP_SET_OPERATOR);
    }
}
