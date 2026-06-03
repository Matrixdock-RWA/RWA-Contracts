// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import {IMTokenRateLimiter} from "./interfaces/IMTokenRateLimiter.sol";
import {MToken} from "./MToken.sol";

// MTokenRateLimiter is non-upgradable
contract MTokenRateLimiter is RateLimiter, IMTokenRateLimiter {
    struct RateLimitedMsg {
        address receiver;
        uint256 amount;
        bytes sender;
    }

    // We use a fake dstEID to achieve global rate limiting.
    uint32 constant GLOBAL_DST_EID = 1;

    // mToken address
    MToken public immutable mToken;

    // state variables
    uint256 public singleMsgLimit;
    mapping(bytes32 key => bool flag) public whitelist;
    RateLimitedMsg[] public rateLimitedMsgs;
    uint256 public pendingMsgCount;

    // events
    event SingleMsgLimitUpdated(uint256 indexed newLimit);
    event WhitelistUpdated(bytes sender, address indexed receiver, bool flag);
    event RateLimitedMsgRemoved(uint256 indexed index);
    event RateLimitedMsgAdded(
        uint256 indexed index,
        address indexed receiver,
        uint256 amount,
        bytes sender
    );

    // errors
    error NotMToken(address sender);
    error NotMTokenOwner(address sender);
    error RateLimitedMsgInvalid(uint256 index);

    modifier onlyMToken() {
        if (msg.sender != address(mToken)) {
            revert NotMToken(msg.sender);
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != mToken.owner()) {
            revert NotMTokenOwner(msg.sender);
        }
        _;
    }

    constructor(address _mToken, uint256 limit, uint256 window) {
        mToken = MToken(_mToken);
        _setRateLimit(limit, window);
    }

    // Configure the global rate limit for incoming cross-chain token transfers.
    //
    // Parameter semantics:
    //   limit=0  — blocks ALL incoming transfers (amountCanBeSent == 0 always).
    //              To disable rate limiting entirely, set rateLimiter to address(0) on MToken instead.
    //   window=0 — LZ's _amountCanBeSent uses (_window > 0 ? _window : 1), so no division-by-zero.
    //              Effectively means instant full decay each block (unlimited throughput), not "disabled".
    function setRateLimit(uint256 limit, uint256 window) public onlyOwner {
        _setRateLimit(limit, window);
    }

    function _setRateLimit(uint256 limit, uint256 window) private {
        RateLimiter.RateLimitConfig[]
            memory configs = new RateLimiter.RateLimitConfig[](1);
        configs[0] = RateLimiter.RateLimitConfig({
            dstEid: GLOBAL_DST_EID,
            limit: limit,
            window: window
        });
        _setRateLimits(configs);
    }

    // Return the configured rate limit parameters.
    function getRateLimit()
        public
        view
        returns (uint256 limit, uint256 window)
    {
        RateLimiter.RateLimit memory rl = rateLimits[GLOBAL_DST_EID];
        return (rl.limit, rl.window);
    }

    // Configure the single message limit for incoming cross-chain token transfers.
    function setSingleMsgLimit(uint256 limit) public onlyOwner {
        singleMsgLimit = limit;
        emit SingleMsgLimitUpdated(limit);
    }

    // Configure the whitelist for incoming cross-chain token transfers.
    function updateWhitelist(
        bytes calldata sender,
        address receiver,
        bool flag
    ) public onlyOwner {
        bytes32 key = getWhitelistKey(sender, receiver);
        whitelist[key] = flag;
        emit WhitelistUpdated(sender, receiver, flag);
    }

    // Check whether an incoming cross-chain token transfer is in the whitelist.
    function isInWhitelist(
        bytes calldata sender,
        address receiver
    ) public view returns (bool) {
        bytes32 key = getWhitelistKey(sender, receiver);
        return whitelist[key];
    }

    // Get the key for the whitelist.
    function getWhitelistKey(
        bytes calldata sender,
        address receiver
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, receiver));
    }

    // Return true if there are any live (not-yet-processed) queued messages.
    // MToken consults this before detaching/replacing the rate limiter to avoid
    // orphaning queued messages (their tokens would otherwise never be minted).
    function hasPendingMsgs() external view returns (bool) {
        return pendingMsgCount != 0;
    }

    // Return the length of the rateLimitedMsgs array, including holes (deleted entries).
    // Callers must handle holes by checking amount == 0 before processing each entry.
    function rateLimitedMsgsLength() public view returns (uint256) {
        return rateLimitedMsgs.length;
    }

    // Called by MToken to deliver or discard a queued message.
    //
    // Deletion uses `delete` rather than swap-and-pop to preserve index stability:
    // once a message is assigned an index (emitted in RateLimitedMsgAdded), that index
    // remains valid and unchanged for all other pending messages. This allows off-chain
    // systems to reliably reference messages by their emitted index.
    // Deleted slots have amount == 0 and are rejected as invalid on access.
    function removeRateLimitedMsg(
        uint256 index
    )
        public
        onlyMToken
        returns (address receiver, uint256 amount, bytes memory sender)
    {
        RateLimitedMsg memory _msg = rateLimitedMsgs[index];
        if (_msg.amount == 0) {
            revert RateLimitedMsgInvalid(index);
        }
        delete rateLimitedMsgs[index];
        pendingMsgCount -= 1;
        emit RateLimitedMsgRemoved(index);
        return (_msg.receiver, _msg.amount, _msg.sender);
    }

    // Check whether an incoming cross-chain token transfer is within the rate limit,
    // and update the in-flight counter if so.
    // Returns true if within limit, false otherwise.
    function checkAndUpdateRateLimit(
        address receiver,
        uint256 amount,
        bytes calldata sender
    ) external onlyMToken returns (bool) {
        if (isInWhitelist(sender, receiver)) {
            return true; // in the whitelist
        }

        if (checkSingleMsgLimit(amount) && _outflow2(GLOBAL_DST_EID, amount)) {
            return true; // within limit
        }

        // queue the message
        uint256 index = rateLimitedMsgs.length;
        rateLimitedMsgs.push(
            RateLimitedMsg({receiver: receiver, amount: amount, sender: sender})
        );
        pendingMsgCount += 1;
        emit RateLimitedMsgAdded(index, receiver, amount, sender);
        return false;
    }

    function checkSingleMsgLimit(uint256 amount) private view returns (bool) {
        uint256 _singleMsgLimit = singleMsgLimit;
        return _singleMsgLimit == 0 || _singleMsgLimit >= amount;
    }

    // Note that the RateLimiter is primarily designed to enforce rate limits on the source side,
    // but in our case, we are using it to enforce rate limits on the destination side.
    //
    // _outflow reverts on exceeded limit, but we need to queue the message instead of reverting.
    // So we implement _outflow2, which returns false instead of reverting when the limit is exceeded.
    function _outflow2(
        uint32 _dstEid,
        uint256 _amount
    ) internal returns (bool) {
        // @dev By default dstEid that have not been explicitly set will return amountCanBeSent == 0.
        RateLimit storage rl = rateLimits[_dstEid];

        (
            uint256 currentAmountInFlight,
            uint256 amountCanBeSent
        ) = _amountCanBeSent(
                rl.amountInFlight,
                rl.lastUpdated,
                rl.limit,
                rl.window
            );
        // if (_amount > amountCanBeSent) revert RateLimitExceeded();
        if (_amount > amountCanBeSent) {
            return false;
        }

        // @dev Update the storage to contain the new amount and current timestamp.
        rl.amountInFlight = currentAmountInFlight + _amount;
        rl.lastUpdated = block.timestamp;
        return true;
    }

    function amountCanBeReceived() public view returns (uint256, uint256) {
        RateLimit storage rl = rateLimits[GLOBAL_DST_EID];
        (
            uint256 currentAmountInFlight,
            uint256 _amountCanBeReceived
        ) = _amountCanBeSent(
                rl.amountInFlight,
                rl.lastUpdated,
                rl.limit,
                rl.window
            );
        return (currentAmountInFlight, _amountCanBeReceived);
    }
}
