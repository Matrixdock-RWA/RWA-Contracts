// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import {IMTokenRateLimiter} from "./interfaces/IMTokenRateLimiter.sol";
import {DelayedRolesUpgradeable} from "./DelayedRolesUpgradeable.sol";
import {MToken} from "./MToken.sol";

/**
 Operation           | Initiator  | Timelock | Revoker
---------------------+------------+----------+---------------
addToWhitelist       | Owner      | govDelay | Owner/Revoker
removeFromWhitelist  | Owner      | no       | no
setRateLimit         | Owner      | delay    | Owner/Revoker
setSingleMsgLimit    | Owner      | delay    | Owner/Revoker
 */

contract MTokenRateLimiter is RateLimiter, IMTokenRateLimiter, DelayedRolesUpgradeable {
    struct RateLimitedMsg {
        address receiver;
        uint256 amount;
        bytes sender;
    }

    // We use a fake dstEID to achieve global rate limiting.
    uint32 constant GLOBAL_DST_EID = 1;

    // delayed operation tags
    bytes32 constant OP_SET_RATE_LIMIT       = keccak256("OP_SET_RATE_LIMIT");       // 0xc3c1a960abb6eac44af87be9ee46a080b15c0d3de70ca598dfae0c2e3949385c
    bytes32 constant OP_SET_SINGLE_MSG_LIMIT = keccak256("OP_SET_SINGLE_MSG_LIMIT"); // 0xeefc3982fcb7ffebc2dc92613272f9999626ab7038977c9e8aa7c443e7e0de6d
    bytes32 constant OP_ADD_TO_WHITELIST     = keccak256("OP_ADD_TO_WHITELIST");     // 0x10aa1371d861e2f58a9b1412ce604884daa18d7b10d56aced483182df1a2cf34

    // mToken address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    MToken public immutable mToken;

    // state variables
    uint256 public singleMsgLimit;
    mapping(bytes32 key => bool flag) public whitelist;
    RateLimitedMsg[] public rateLimitedMsgs;
    uint256 public pendingMsgCount;

    // events
    event AddedToWhitelist(bytes sender, address indexed receiver);
    event RemovedFromWhitelist(bytes sender, address indexed receiver);
    event RateLimitedMsgRemoved(uint256 indexed index);
    event RateLimitedMsgAdded(
        uint256 indexed index,
        address indexed receiver,
        uint256 amount,
        bytes sender
    );

    // errors
    error NotMToken(address sender);
    error RateLimitedMsgInvalid(uint256 index);
    error RateLimitTooLarge(uint256 limit, uint256 window);
    error SingleMsgLimitTooLarge(uint256 limit);

    modifier onlyMToken() {
        if (msg.sender != address(mToken)) {
            revert NotMToken(msg.sender);
        }
        _;
    }

    modifier onlyOwnerOrRevoker() {
        if (msg.sender != owner() && msg.sender != revoker) {
            revert NotOwnerOrRevoker(msg.sender);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _mToken) {
        mToken = MToken(_mToken);
        _disableInitializers();
    }

    // Note: govDelay and delay are intentionally initialized to 0 (delayed ops execute immediately).
    // Call setGovDelay / setDelay twice after deployment to activate the time-locks.
    function initialize(
        address _owner,
        address _operator,
        address _revoker,
        uint256 limit,
        uint256 window
    ) public initializer {
        __DelayedRolesUpgradeable_init(_owner, _operator, _revoker);
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
        // Packs (window, limit) into uint160: upper 32 bits = window, lower 128 bits = limit.
        // Assumes window < 2^32 (~136 years) and limit < 2^128. Both hold for any realistic
        // rate-limit config.
        if (limit > type(uint128).max || window > type(uint32).max) {
            revert RateLimitTooLarge(limit, window);
        }
        RateLimiter.RateLimit storage rl = rateLimits[GLOBAL_DST_EID];
        uint160 _oldVal = uint160(rl.window << 128 | rl.limit);
        uint160 _newVal = uint160(window << 128 | limit);
        if (ensureDelay(OP_SET_RATE_LIMIT, _oldVal, _newVal, delay)) {
            _setRateLimit(limit, window);
        }
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

    function revokeSetRateLimit() public onlyOwnerOrRevoker {
        revoke(OP_SET_RATE_LIMIT);
    }

    // Return the configured rate limit parameters.
    function getRateLimit()
        public
        view
        returns (uint256 limit, uint256 window)
    {
        RateLimiter.RateLimit storage rl = rateLimits[GLOBAL_DST_EID];
        return (rl.limit, rl.window);
    }

    // Configure the single message limit for incoming cross-chain token transfers.
    function setSingleMsgLimit(uint256 limit) public onlyOwner {
        // Assumes limit < 2^160. Holds for any realistic token amount (9 decimals,
        // 2^160 ≈ 1.46e39 tokens)
        if (limit > type(uint160).max) {
            revert SingleMsgLimitTooLarge(limit);
        }
        if (ensureDelay(OP_SET_SINGLE_MSG_LIMIT, uint160(singleMsgLimit), uint160(limit), delay)) {
            singleMsgLimit = limit;
        }
    }

    function revokeSetSingleMsgLimit() public onlyOwnerOrRevoker {
        revoke(OP_SET_SINGLE_MSG_LIMIT);
    }

    // Add a (sender, receiver) pair to the whitelist for incoming cross-chain token transfers.
    function addToWhitelist(
        bytes calldata sender,
        address receiver
    ) public onlyOwner {
        bytes32 reqHash = _addToWhitelistReqHash(sender, receiver);
        if (ensureGovDelay(reqHash, 0, 0)) {
            whitelist[getWhitelistKey(sender, receiver)] = true;
            emit AddedToWhitelist(sender, receiver);
        } else {
            emit DelayedOpExtraData(reqHash, OP_ADD_TO_WHITELIST,
                abi.encode(sender, receiver));
        }
    }

    function revokeAddToWhitelist(
        bytes calldata sender,
        address receiver
    ) public onlyOwnerOrRevoker {
        revoke(_addToWhitelistReqHash(sender, receiver));
    }

    function _addToWhitelistReqHash(
        bytes calldata sender,
        address receiver
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(OP_ADD_TO_WHITELIST, sender, receiver));
    }

    // Remove a (sender, receiver) pair from the whitelist immediately.
    // Note: if an addToWhitelist request is still pending for the same pair, it will re-add the
    // entry when executed. Call revokeAddToWhitelist first to cancel it if that is not desired.
    function removeFromWhitelist(
        bytes calldata sender,
        address receiver
    ) public onlyOwner {
        whitelist[getWhitelistKey(sender, receiver)] = false;
        emit RemovedFromWhitelist(sender, receiver);
    }

    // Check whether an incoming cross-chain token transfer is in the whitelist.
    function isInWhitelist(
        bytes calldata sender,
        address receiver
    ) public view returns (bool) {
        return whitelist[getWhitelistKey(sender, receiver)];
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
        external
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

    // Called by MToken before registering/maturing a delayed process/discard request,
    // so a request can't be pre-planted for an index that doesn't hold a message yet
    // (and later mature against whatever unrelated message eventually lands there).
    function checkRateLimitedMsg(uint256 index) external view {
        if (index >= rateLimitedMsgs.length || rateLimitedMsgs[index].amount == 0) {
            revert RateLimitedMsgInvalid(index);
        }
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
    ) private returns (bool) {
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
