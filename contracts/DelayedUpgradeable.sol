// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract DelayedUpgradeable is OwnableUpgradeable, UUPSUpgradeable {
    // upgradeToAndCall() is delayed
    address public nextImplementation;
    bytes32 public nextUpgradeToAndCallDataHash;
    uint64 public etNextUpgradeToAndCall; //effective time

    event UpgradeToAndCallRequest(address newImplementation, bytes data);

    error InvalidUpgradeToAndCallImpl();
    error InvalidUpgradeToAndCallData();
    error TooEarlyToUpgradeToAndCall();
    error ZeroAddress();

    function getDelay() internal virtual returns (uint64);

    function requestUpgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    ) public onlyOwner {
        nextImplementation = _newImplementation;
        nextUpgradeToAndCallDataHash = keccak256(_data);
        etNextUpgradeToAndCall = uint64(block.timestamp) + getDelay();
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

        // _authorizeUpgrade(newImplementation);
        // _upgradeToAndCallUUPS(newImplementation, data);
        super.upgradeToAndCall(_newImplementation, _data);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function _checkZeroAddress(address _addr) internal pure {
        if (_addr == address(0)) {
            revert ZeroAddress();
        }
    }
}
