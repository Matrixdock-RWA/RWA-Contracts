// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract Ownable2StepTimeLockUpgradeable is Initializable, OwnableUpgradeable {
    uint64 public constant MIN_DELAY = 1 hours;
    uint64 public constant MAX_DELAY = 7 days;

    struct Ownable2StepTimeLockStorage {
        address _pendingOwner;
        uint64 _etNextOwner; // effective time of the pending owner, 0 if no pending owner
        uint64 _delay;
        uint64 _nextDelay;
        uint64 _etNextDelay;
    }

    // keccak256(abi.encode(uint256(keccak256("mtoken.storage.Ownable2StepTimeLock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant Ownable2StepTimeLockStorageLocation = 0x16030feb93ab6ffbb9625d389064b27c758ffe396f5e8796b88f1ac433a17300;

    function _getOwnable2StepTimeLockStorage() private pure returns (Ownable2StepTimeLockStorage storage $) {
        assembly {
            $.slot := Ownable2StepTimeLockStorageLocation
        }
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner, uint64 etNextOwner);
    event OwnershipTransferRevoked(address indexed pendingOwner);
    event SetGovDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetGovDelayEffected(uint64 newDelay);
    event RevokeNextGovDelay();

    error DelayTooSmall();
    error DelayTooLarge();
    error PendingOwnerExist(address pendingOwner);
    error PendingGovDelayExist(uint64 nextDelay);
    error TooEarlyToSetGovDelay(uint64 effectiveTime);
    error TooEarlyToAcceptOwnership(uint64 effectiveTime);
    error NotSupport();

    function __Ownable2StepTimeLock_init() internal onlyInitializing {
    }

    function __Ownable2StepTimeLock_init_unchained() internal onlyInitializing {
    }

    function pendingOwner() public view virtual returns (address) {
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        return $._pendingOwner;
    }

    function etNextOwner() public view virtual returns (uint64) {
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        return $._etNextOwner;
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        if ($._etNextOwner != 0) {
            revert PendingOwnerExist($._pendingOwner);
        }
        $._pendingOwner = newOwner;
        $._etNextOwner = uint64(block.timestamp) + $._delay;
        emit OwnershipTransferStarted(owner(), newOwner, $._etNextOwner);
    }

    function revokeOwnershipTransfer() public virtual onlyOwner {
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        address pending = $._pendingOwner;
        delete $._pendingOwner;
        delete $._etNextOwner;
        emit OwnershipTransferRevoked(pending);
    }

    function acceptOwnership() public virtual {
        address sender = _msgSender();
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
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
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        return $._delay;
    }

    function setGovDelay(uint64 newDelay) public virtual onlyOwner {
        if (newDelay < MIN_DELAY) {
            revert DelayTooSmall();
        } else if (newDelay > MAX_DELAY) {
            revert DelayTooLarge();
        }
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        uint64 _et = $._etNextDelay;
        uint64 _nextDelay = $._nextDelay;
        if (_et != 0) {
            if (newDelay != _nextDelay) {
                revert PendingGovDelayExist(_nextDelay);
            }
            if (_et > block.timestamp) {
                revert TooEarlyToSetGovDelay(_et);
            }
            $._delay = newDelay;
            delete $._nextDelay;
            delete $._etNextDelay;
            emit SetGovDelayEffected(newDelay);
            return;
        }
        uint64 _currDelay = $._delay;
        uint64 _etNextDelay = uint64(block.timestamp) + _currDelay;
        $._nextDelay = newDelay;
        $._etNextDelay = _etNextDelay;
        emit SetGovDelayRequest(_currDelay, newDelay, _etNextDelay);
    }

    function revokeNextGovDelay() public virtual onlyOwner {
        Ownable2StepTimeLockStorage storage $ = _getOwnable2StepTimeLockStorage();
        delete $._nextDelay;
        delete $._etNextDelay;
        emit RevokeNextGovDelay();
    }
}
