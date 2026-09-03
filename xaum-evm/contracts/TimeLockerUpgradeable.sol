// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// Extends OZ OwnableUpgradeable with two safety layers on top of the standard single-step owner model:
//
//   1. Two-step ownership transfer — the new owner must call acceptOwnership() to confirm,
//      preventing accidental transfers to wrong addresses.
//
//   2. Time-lock (govDelay) — every ownership transfer and govDelay change must sit in a
//      pending queue for at least govDelay seconds before it can take effect.  This gives
//      the team a window to detect and cancel rogue transactions before they land.
//      govDelay must be between MIN_GOV_DELAY (1 day) and MAX_GOV_DELAY (7 days);
//      operational delays use MIN_DELAY (1 hour) to MAX_DELAY (48 hours).
//
// Pending requests are stored in a keccak256-keyed mapping (requestMap) inside ERC-7201
// namespaced storage.  Sub-contracts inherit ensureDelay / ensureGovDelay / revoke
// helpers to plug their own delayed operations into the same queue.
//
// renounceOwnership is disabled: a contract with no owner would be permanently bricked.
abstract contract TimeLockerUpgradeable is Initializable, OwnableUpgradeable {

    uint64 constant MIN_GOV_DELAY = 1 days;
    uint64 constant MAX_GOV_DELAY = 7 days;
    uint64 constant MIN_DELAY = 1 hours;
    uint64 constant MAX_DELAY = 48 hours;

    // common delayed operations
    bytes32 constant OP_SET_GOV_DELAY = keccak256("OP_SET_GOV_DELAY"); // 0x83f6c7038baf02a8a3e8878d33a0ac41ea896aa36cbc5232c26caf7d0c8dc007
    bytes32 constant OP_SET_DELAY     = keccak256("OP_SET_DELAY");     // 0xa24d58aaa8deed8b2ff0e63d867e6fe155de046522ed61849f5647e59d04b6ba
    bytes32 constant OP_SET_OPERATOR  = keccak256("OP_SET_OPERATOR");  // 0xda1e7f567d826bc6c713d4e11c7d22d3380d64ddede938b7509777181de23b33
    bytes32 constant OP_SET_REVOKER   = keccak256("OP_SET_REVOKER");   // 0x20fc371924be5c4e542bb9b06260e35c09ca3bb7852d9a9f847c9a97c5e88cca

    struct RequestInfo {
        uint64 effectiveTime;
        uint160 newValue; // only used by delayed set
    }

    struct TimeLockerStorage {
        address _pendingOwner;
        uint64 _etNextOwner; // effective time of the pending owner, 0 if no pending owner
        uint64 _delay; // govDelay
        mapping(bytes32 requestHash => RequestInfo requestInfo) _requestMap;
    }

    // keccak256(abi.encode(uint256(keccak256("mtoken.storage.TimeLocker")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TimeLockerStorageLocation = 0x98e6fd94df2c357acf8f582bd7e6da6abad079cc3e0027785549e47234e7ce00;

    function _getTimeLockerStorage() private pure returns (TimeLockerStorage storage $) {
        assembly {
            $.slot := TimeLockerStorageLocation
        }
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner, uint64 etNextOwner);
    event OwnershipTransferRevoked(address indexed pendingOwner);

    event DelayedOpRequest(bytes32 indexed reqHash, uint160 oldVal, uint160 newVal, uint64 et);
    event DelayedOpEffected(bytes32 indexed reqHash, uint160 newVal);
    event DelayedOpExtraData(bytes32 indexed reqHash, bytes32 indexed opId, bytes data);
    event RequestRevoked(bytes32 indexed reqHash);

    error TooEarlyToExecute(bytes32 reqHash);
    error RequestArgsMismatch(bytes32 reqHash);
    error NoPendingRequest(bytes32 reqHash);
    error DelayTooSmall();
    error DelayTooLarge();
    error PendingOwnerExist(address pendingOwner);
    error TooEarlyToAcceptOwnership(uint64 effectiveTime);
    error NotSupport();

    // some common errors used by sub-contracts
    error NotOperator(address);
    error NotRevoker(address);
    error NotOwnerOrRevoker(address);
    error NotOwnerOrOperator(address);
    error NotNewRevoker(address caller);

    function __TimeLockerUpgradeable_init() internal onlyInitializing {
    }

    function __TimeLockerUpgradeable_init_unchained() internal onlyInitializing {
    }

    // For historical reasons the operational delay lives in the sub-contract's
    // storage (unlike govDelay, which is kept here), so reading it goes through
    // this virtual getter.
    function getDelay() internal virtual view returns (uint64);

    function checkDelay(uint64 newDelay) internal view {
        if (newDelay < MIN_DELAY) {
            revert DelayTooSmall();
        } 
        if (newDelay > MAX_DELAY || newDelay > getGovDelay()) {
            revert DelayTooLarge();
        }
    }

    function checkGovDelay(uint64 newGovDelay) internal view {
        if (newGovDelay < MIN_GOV_DELAY || newGovDelay < getDelay()) {
            revert DelayTooSmall();
        } 
        if (newGovDelay > MAX_GOV_DELAY) {
            revert DelayTooLarge();
        }
    }

    function ensureDelay(
        bytes32 reqHash,
        uint160 oldVal,
        uint160 newVal,
        uint64 delay
    ) internal returns (bool effected) {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        return _ensureDelay($._requestMap, reqHash, oldVal, newVal, delay);
    }

    function ensureGovDelay(
        bytes32 reqHash,
        uint160 oldVal,
        uint160 newVal
    ) internal returns (bool effected) {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        return _ensureDelay($._requestMap, reqHash, oldVal, newVal, $._delay);
    }

    function _ensureDelay(
        mapping(bytes32 requestHash => RequestInfo requestInfo) storage _requestMap,
        bytes32 reqHash,
        uint160 oldVal,
        uint160 newVal,
        uint64 delay
    ) private returns (bool effected) {
        RequestInfo storage reqInfo = _requestMap[reqHash];
        uint64 storedEt = reqInfo.effectiveTime;
        uint160 storedVal = reqInfo.newValue; // same slot as storedEt, one SLOAD

        if (storedEt == 0) {
            // add a new record
            uint64 et = uint64(block.timestamp) + delay;
            reqInfo.effectiveTime = et;
            reqInfo.newValue = newVal;
            emit DelayedOpRequest(reqHash, oldVal, newVal, et);
            return false;
        }

        // check delay & newValue
        if (storedEt > block.timestamp) {
            revert TooEarlyToExecute(reqHash);
        }
        if (storedVal != newVal) {
            revert RequestArgsMismatch(reqHash);
        }

        delete _requestMap[reqHash];
        emit DelayedOpEffected(reqHash, newVal);
        return true;
    }

    // Idempotent on purpose: revoking is a safety action, so it must never fail —
    // even if the request was already revoked, executed, or never made (e.g. two
    // guardians racing to cancel the same rogue request).
    function revoke(bytes32 reqHash) internal {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        if ($._requestMap[reqHash].effectiveTime > 0) {
            delete $._requestMap[reqHash];
            emit RequestRevoked(reqHash);
        }
    }

    function requestMap(bytes32 reqHash) public view returns (RequestInfo memory) {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        return $._requestMap[reqHash];
    }

    function pendingOwner() public view virtual returns (address) {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        return $._pendingOwner;
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        if ($._etNextOwner != 0) {
            revert PendingOwnerExist($._pendingOwner);
        }
        $._pendingOwner = newOwner;
        $._etNextOwner = uint64(block.timestamp) + $._delay;
        emit OwnershipTransferStarted(owner(), newOwner, $._etNextOwner);
    }

    function revokeOwnershipTransfer() public virtual onlyOwner {
        _revokeOwnershipTransfer();
    }

    function _revokeOwnershipTransfer() internal {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        address pending = $._pendingOwner;
        delete $._pendingOwner;
        delete $._etNextOwner;
        emit OwnershipTransferRevoked(pending);
    }

    function acceptOwnership() public virtual {
        address sender = _msgSender();
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        if ($._pendingOwner != sender) {
            revert OwnableUnauthorizedAccount(sender);
        }
        uint64 et = $._etNextOwner;
        if (et > block.timestamp) {
            revert TooEarlyToAcceptOwnership(et);
        }
        delete $._pendingOwner;
        delete $._etNextOwner;
        _transferOwnership(sender);
    }

    function renounceOwnership() public virtual override onlyOwner {
        revert NotSupport();
    }

    function getGovDelay() public view virtual returns (uint64) {
        TimeLockerStorage storage $ = _getTimeLockerStorage();
        return $._delay;
    }

    function setGovDelay(uint64 newGovDelay) public virtual onlyOwner {
        checkGovDelay(newGovDelay);

        TimeLockerStorage storage $ = _getTimeLockerStorage();
        uint64 oldGovDelay = $._delay;

        if (_ensureDelay($._requestMap, OP_SET_GOV_DELAY, oldGovDelay, newGovDelay, oldGovDelay)) {
            $._delay = newGovDelay;
        }
    }

    function revokeNextGovDelay() public virtual onlyOwner {
        _revokeNextGovDelay();
    }

    function _revokeNextGovDelay() internal {
        revoke(OP_SET_GOV_DELAY);
    }

}
