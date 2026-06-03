// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

interface IMTokenRateLimiter {
    // Returns true if within rate limit (tokens should be minted).
    // Returns false if exceeded (message queued for admin review, tokens must NOT be minted).
    function checkAndUpdateRateLimit(address receiver, uint256 amount, bytes calldata sender) external returns (bool);

    // Called by MToken to deliver or discard a queued message.
    function removeRateLimitedMsg(uint256 index) external returns (address receiver, uint256 amount, bytes memory sender);

    // Returns true if there are queued messages not yet processed.
    function hasPendingMsgs() external view returns (bool);

}
