// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TimeLockerUpgradeable} from "./TimeLockerUpgradeable.sol";

abstract contract DelayedUpgradeable is TimeLockerUpgradeable, UUPSUpgradeable {
    // upgradeToAndCall() is delayed
    address public nextImplementation;
    bytes32 public nextUpgradeToAndCallDataHash;
    uint64 public etNextUpgradeToAndCall; //effective time

    event UpgradeToAndCallRequest(address newImplementation, bytes data);
    event NextUpgradeRevoked(bytes32 nextDataHash);

    error InvalidUpgradeToAndCallImpl();
    error InvalidUpgradeToAndCallData();
    error TooEarlyToUpgradeToAndCall();
    error ZeroAddress();

    function requestUpgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    ) public onlyOwner {
        _checkZeroAddress(_newImplementation);
        nextImplementation = _newImplementation;
        nextUpgradeToAndCallDataHash = keccak256(_data);
        etNextUpgradeToAndCall = uint64(block.timestamp) + getGovDelay();
        emit UpgradeToAndCallRequest(_newImplementation, _data);
    }

    function upgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    ) public payable override onlyProxy {
        if (_newImplementation != nextImplementation) {
            revert InvalidUpgradeToAndCallImpl();
        }
        if (keccak256(_data) != nextUpgradeToAndCallDataHash) {
            revert InvalidUpgradeToAndCallData();
        }

        uint64 et = etNextUpgradeToAndCall;
        if (et == 0 || et > block.timestamp) {
            revert TooEarlyToUpgradeToAndCall();
        }

        // consume the authorization before upgrading, so a request
        // can be executed only once
        delete nextImplementation;
        delete nextUpgradeToAndCallDataHash;
        delete etNextUpgradeToAndCall;

        // _authorizeUpgrade(newImplementation);
        // _upgradeToAndCallUUPS(newImplementation, data);
        super.upgradeToAndCall(_newImplementation, _data);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // default implementation
    function revokeNextUpgrade() public virtual onlyOwner {
        _revokeNextUpgrade();
    }

    function _revokeNextUpgrade() internal {
        etNextUpgradeToAndCall = 0;
        emit NextUpgradeRevoked(nextUpgradeToAndCallDataHash);
    }

    function _checkZeroAddress(address _addr) internal pure {
        if (_addr == address(0)) {
            revert ZeroAddress();
        }
    }
}
