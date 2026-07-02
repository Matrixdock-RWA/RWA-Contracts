// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.20;

library DelayedRequests {
    error TooEarlyToExecute(bytes32 reqHash);
    error RequestArgsMismatch(bytes32 reqHash);

    struct RequestInfo {
        uint64 effectiveTime;
        uint160 newValue; // only used by delayed set
    }

    function ensureDelay(
        mapping(bytes32 requestHash => RequestInfo requestInfo) storage requestMap,
        bytes32 reqHash,
        uint160 newVal,
        uint64 delay
    ) internal returns (uint64 et) {
        RequestInfo storage reqInfo = requestMap[reqHash];
        uint64 storedEt = reqInfo.effectiveTime;
        uint160 storedVal = reqInfo.newValue; // same slot as storedEt, one SLOAD

        if (storedEt == 0) {
            // add a new record
            et = uint64(block.timestamp) + delay;
            reqInfo.effectiveTime = et;
            reqInfo.newValue = newVal;
            return et;
        }

        // check delay & newValue
        if (storedEt >= block.timestamp) {
            revert TooEarlyToExecute(reqHash);
        }
        if (storedVal != newVal) {
            revert RequestArgsMismatch(reqHash);
        }

        delete requestMap[reqHash];
        // et stays 0 -> effected
    }
}
