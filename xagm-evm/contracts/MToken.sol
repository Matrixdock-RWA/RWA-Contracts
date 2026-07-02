// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";
import {IMTokenRateLimiter} from "./interfaces/IMTokenRateLimiter.sol";
import {DelayedRequests} from "./libraries/DelayedRequests.sol";
// import "hardhat/console.sol";

abstract contract MTokenBase is ERC20PermitUpgradeable, DelayedUpgradeable {

    // every chain has its own mintBudget, operator can move mintBudget from one chain to another
    uint112 public mintBudget;

    // sensitive operation must be delayed before taking effect
    uint64 public delay;
    uint64 private __nextDelay; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextDelay; // dead slot — preserved for upgradeable storage layout

    // the operator takes care of everyday operations
    address public operator;
    address private __nextOperator; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextOperator; // dead slot — preserved for upgradeable storage layout

    // a revoker can delete delayed operations before they taking effect
    address public revoker;
    address private __nextRevoker; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextRevoker; // dead slot — preserved for upgradeable storage layout

    // the messenger contract takes care of cross-chain task
    address public messenger;
    address private __nextMessenger; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextMessenger; // dead slot — preserved for upgradeable storage layout

    // the delayed minting requests are stored in requestMap
    mapping(bytes32 requestHash => DelayedRequests.RequestInfo requestInfo) public requestMap;

    // suspicious accounts can be blocked
    mapping(address account => bool blocked) public isBlocked;

    bool public disableCcSend;

    // totalTokenObligation = Sum of each chain's totalSupply and mintBudget
    // totalTokenObligation * ozPerToken <= Chainlink's PoR
    uint112 public totalTokenObligation;

    // ChainLink PoR
    address public reserveFeed;
    address private __nextReserveFeed; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextReserveFeed; // dead slot — preserved for upgradeable storage layout
    address public fallbackFeed;
    address private __nextFallbackFeed; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextFallbackFeed; // dead slot — preserved for upgradeable storage layout

    // the address that collects the fee tokens
    address public feeCollector;
    address private __nextFeeCollector; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextFeeCollector; // dead slot — preserved for upgradeable storage layout

    uint64 public lastReconcileTime; // timestamp of the last reconcile (fee minting), rounded to daily boundary
    uint64 public ozPerTokenBaseTime; // timestamp of the update of annualFeeRate & ozPerTokenBase, rounded to daily boundary
    uint64 public annualFeeRate; // the annual fee rate, 9 decimals
    uint64 public ozPerTokenBase; // calculated when annualFeeRate is updated, 9 decimals

    // RateLimiter
    address public rateLimiter;

    // Global pause flag
    bool public paused;

    // the designated receiver for forced transfers of blocked accounts
    address public forcedTransferReceiver;

}

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCClient {
    using SafeCast for uint256;

    uint256 constant TAG_SEND_TOKEN = 2;
    uint256 constant TAG_SEND_MINT_BUDGET = 3;

    uint64 constant SECONDS_PER_DAY = 24 * 3600; // lastReconcileTime & ozPerTokenBaseTime are rounded to daily boundary
    uint64 constant DAYS_PER_YEAR = 365; // dailyFeeRate is annualFeeRate / DAYS_PER_YEAR
    uint64 constant FEE_RATE_BASE = 10 ** 9; // feeRate is 9 decimals
    uint64 constant OZ_RATIO_BASE = 10 ** 9; // ozPerToken is 9 decimals
    uint64 constant MAX_ANNUAL_FEE_RATE = FEE_RATE_BASE / 10; // 10%

    // delayed operation tags
    uint8 constant OP_SET_DELAY = 1;
    uint8 constant OP_SET_OPERATOR = 2;
    uint8 constant OP_SET_REVOKER = 3;
    uint8 constant OP_SET_MESSENGER = 4;
    uint8 constant OP_SET_RESERVE_FEED = 5;
    uint8 constant OP_SET_FALLBACK_FEED = 6;
    uint8 constant OP_SET_RATE_LIMITER = 7;
    uint8 constant OP_SET_FORCED_TRANSFER_RECEIVER = 8;
    uint8 constant OP_FORCED_TRANSFER = 9;
    uint8 constant OP_MINT = 10;
    uint8 constant OP_SET_FEE_COLLECTOR = 11;

    event SetDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetDelayEffected(uint64 newDelay);
    event SetOperatorRequest(address oldAddr, address newAddr, uint64 et);
    event SetOperatorEffected(address newAddr);
    event SetRevokerRequest(address oldAddr, address newAddr, uint64 et);
    event SetRevokerEffected(address newAddr);
    event SetMessengerRequest(address oldAddr, address newAddr, uint64 et);
    event SetMessengerEffected(address newAddr);
    event SetRateLimiterRequest(address oldAddr, address newAddr, uint64 et);
    event SetRateLimiterEffected(address newAddr);
    event SetForcedTransferReceiverRequest(address oldAddr, address newAddr, uint64 et);
    event SetForcedTransferReceiverEffected(address newAddr);
    event BlockPlaced(address indexed _user);
    event BlockReleased(address indexed _user);
    event CCSendToken(address indexed sender, bytes receiver, uint256 value);
    event CCSendMintBudget(uint112 value);
    event CCSendMintBudgetManually(uint112 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint256 value);
    event CCReceiveMintBudget(uint112 value);
    event CCReceiveMintBudgetManually(uint112 value);
    event Redeem(address indexed customer, uint256 amount, bytes data);
    event MintRequest(address indexed receiver, uint256 amount, uint256 nonce);
    event RequestRevoked(bytes32 indexed req);
    event RateLimitedMsgProcessed(uint256 index);
    event RateLimitedMsgDiscarded(uint256 index);
    event Paused(address indexed _userAddress);
    event Unpaused(address indexed _userAddress);
    event DisableCcSend(bool disabled);
    event NextUpgradeRevoked(bytes32 dataHash);
    event ForcedTransferRequest(address indexed _from, address indexed _to, uint256 _value, bytes _data, bytes _operatorData);
    event UpdateAnnualFeeRate(
        uint64 newAnnualFeeRate,
        uint64 newOzPerTokenBase,
        uint64 roundedUpdateTime
    );
    event ForcedTransfer(
        address indexed _from,
        address indexed _to,
        uint256 _value,
        bytes _data,
        bytes _operatorData
    );

    error BlockedAccount(address);
    error NotBlocked(address);
    error NotOperator(address);
    error NotRevoker(address);
    error NotMessenger(address);
    error MintBudgetNotEnough(uint256 budget, uint256 amount);
    error TransferToContract();
    error ZeroValue();
    error ArgsMismatch();
    error CcSendDisabled();
    error InvalidMsg(uint256 tag);
    error InvalidReceiver(uint256 length);
    error AnnualFeeRateTooLarge();
    error OzPerTokenBaseTooLarge();
    error UnexpectedOzPerToken(uint64 expectedOzPerToken, uint64 actualOzPerToken);
    error GlobalPaused();
    error PendingRateLimitedMsgsExist();
    error InvalidForcedTransferReceiver(address);
    error OwnerOnlyRequest(bytes32 req);

    modifier whenNotPaused() {
        if (paused) {
            revert GlobalPaused();
        }
        _;
    }

    modifier onlyNotBlocked() {
        _checkBlocked(_msgSender());
        _;
    }

    modifier onlyOperator() {
        _checkOperator(msg.sender);
        _;
    }

    modifier onlyRevoker() {
        if (msg.sender != revoker) {
            revert NotRevoker(msg.sender);
        }
        _;
    }

    modifier onlyMessenger() {
        if (msg.sender != messenger) {
            revert NotMessenger(msg.sender);
        }
        _;
    }

    function _checkBlocked(address addr) private view {
        if (isBlocked[addr]) {
            revert BlockedAccount(addr);
        }
    }

    function _checkOperator(address addr) private view {
        if (addr != operator) {
            revert NotOperator(addr);
        }
    }

    function _checkMintBudget(uint256 amount) private view {
        if (amount > mintBudget) {
            revert MintBudgetNotEnough(mintBudget, amount);
        }
    }

    function _checkZeroValue(uint256 value) internal pure {
        if (value == 0) {
            revert ZeroValue();
        }
    }

    function _checkOzPerToken(uint64 expectedOzPerToken) private view {
        uint64 actualOzPerToken = ozPerToken();
        if (expectedOzPerToken != actualOzPerToken) {
            revert UnexpectedOzPerToken(expectedOzPerToken, actualOzPerToken);
        }
    }

    function __MTOKEN_init(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        uint64 _annualFeeRate,
        uint64 _ozPerTokenBase
    ) internal onlyInitializing {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(symbol);
        __Ownable_init(_owner);
        __Ownable2StepTimeLock_init_unchained();
        __MTOKEN_init_unchained(_operator, _annualFeeRate, _ozPerTokenBase);
    }

    function __MTOKEN_init_unchained(
        address _operator,
        uint64 _annualFeeRate,
        uint64 _ozPerTokenBase
    ) internal onlyInitializing {
        operator = _operator;

        checkAnnualFeeRate(_annualFeeRate);
        if (_ozPerTokenBase > OZ_RATIO_BASE) {
            revert OzPerTokenBaseTooLarge();
        }

        uint64 _currDayStartTime = currentDayStartTime();
        lastReconcileTime = _currDayStartTime;
        ozPerTokenBaseTime = _currDayStartTime;
        annualFeeRate = _annualFeeRate;
        ozPerTokenBase = _ozPerTokenBase;
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    // _annualFeeRate can not be greater than MAX_ANNUAL_FEE_RATE (10%)
    function checkAnnualFeeRate(uint64 _annualFeeRate) private pure {
        if (_annualFeeRate > MAX_ANNUAL_FEE_RATE) {
            revert AnnualFeeRateTooLarge();
        }
    }

    // current day start time, rounded to daily boundary
    function currentDayStartTime() internal view returns (uint64) {
        return (block.timestamp.toUint64() / SECONDS_PER_DAY) * SECONDS_PER_DAY;
    }

    // ozPerTokenBase - annualFeeRate*daysElapsed/365
    function ozPerToken() public view returns (uint64) {
        uint64 daysElapsed = (block.timestamp.toUint64() - ozPerTokenBaseTime) / SECONDS_PER_DAY;
        return ozPerTokenBase - (annualFeeRate * daysElapsed) / DAYS_PER_YEAR;
    }

    // get oz amount from token amount
    function getOzAmount(uint256 tokenAmount) public view returns (uint256) {
        return (tokenAmount * ozPerToken()) / OZ_RATIO_BASE;
    }

    function updateAnnualFeeRate(uint64 _annualFeeRate) public onlyOwner {
        checkAnnualFeeRate(_annualFeeRate);
        uint64 _ozPerTokenBase = ozPerToken();
        uint64 _ozPerTokenBaseTime = currentDayStartTime();

        annualFeeRate = _annualFeeRate;
        ozPerTokenBase = _ozPerTokenBase;
        ozPerTokenBaseTime = _ozPerTokenBaseTime;
        emit UpdateAnnualFeeRate(_annualFeeRate, _ozPerTokenBase, _ozPerTokenBaseTime);
    }

    function setDisableCcSend(bool b) public onlyOwner {
        disableCcSend = b;
        emit DisableCcSend(b);
    }

    function pause() external onlyOperator {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function ensureDelay(bytes32 reqHash, uint160 newVal) internal returns (uint64 et) {
        return DelayedRequests.ensureDelay(requestMap, reqHash, newVal, delay);
    }

    function revoke(bytes32 req) internal {
        delete requestMap[req];
        emit RequestRevoked(req);
    }

    function setDelay(uint64 _delay) public onlyOwner {
        if (_delay < MIN_DELAY) {
            revert DelayTooSmall();
        }
        if (_delay > MAX_DELAY) {
            revert DelayTooLarge();
        }

        bytes32 reqId = bytes32(uint256(OP_SET_DELAY));
        uint64 et = ensureDelay(reqId, _delay);
        if (et == 0) {
            delay = _delay;
            emit SetDelayEffected(_delay);
        } else {
            emit SetDelayRequest(delay, _delay, et);
        }
    }

    function setMessenger(address _messenger) public onlyOwner {
        _checkZeroAddress(_messenger);
        bytes32 reqId = bytes32(uint256(OP_SET_MESSENGER));
        uint64 et = ensureDelay(reqId, uint160(_messenger));
        if (et == 0) {
            messenger = _messenger;
            emit SetMessengerEffected(_messenger);
        } else {
            emit SetMessengerRequest(messenger, _messenger, et);
        }
    }

    // note: allows setting rateLimiter to zero address by design
    function setRateLimiter(address _rateLimiter) public onlyOwner {
        // _checkZeroAddress(_rateLimiter);
        bytes32 reqId = bytes32(uint256(OP_SET_RATE_LIMITER));
        uint64 et = ensureDelay(reqId, uint160(_rateLimiter));
        if (et == 0) {
            // The old rate limiter's queue can only be drained through this MToken
            // (removeRateLimitedMsg is onlyMToken). Refuse to detach/replace it while
            // messages are still queued, otherwise those tokens would be orphaned.
            // Process or discard all pending messages first.
            address oldRateLimiter = rateLimiter;
            if (oldRateLimiter != address(0) && IMTokenRateLimiter(oldRateLimiter).hasPendingMsgs()) {
                revert PendingRateLimitedMsgsExist();
            }
            rateLimiter = _rateLimiter;
            emit SetRateLimiterEffected(_rateLimiter);
        } else {
            emit SetRateLimiterRequest(rateLimiter, _rateLimiter, et);
        }
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        bytes32 reqId = bytes32(uint256(OP_SET_REVOKER));
        uint64 et = ensureDelay(reqId, uint160(_revoker));
        if (et == 0) {
            revoker = _revoker;
            emit SetRevokerEffected(_revoker);
        } else {
            emit SetRevokerRequest(revoker, _revoker, et);
        }
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        bytes32 reqId = bytes32(uint256(OP_SET_OPERATOR));
        uint64 et = ensureDelay(reqId, uint160(_operator));
        if (et == 0) {
            operator = _operator;
            emit SetOperatorEffected(_operator);
        } else {
            emit SetOperatorRequest(operator, _operator, et);
        }
    }

    function setForcedTransferReceiver(address _receiver) public onlyOwner {
        _checkZeroAddress(_receiver);
        bytes32 reqId = bytes32(uint256(OP_SET_FORCED_TRANSFER_RECEIVER));
        uint64 et = ensureDelay(reqId, uint160(_receiver));
        if (et == 0) {
            forcedTransferReceiver = _receiver;
            emit SetForcedTransferReceiverEffected(_receiver);
        } else {
            emit SetForcedTransferReceiverRequest(forcedTransferReceiver, _receiver, et);
        }
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    // revoke a pending mintTo or forcedTransfer request; 
    // revoker cannot revoke the revoker rotation (owner-only)
    function revokeRequest(bytes32 req) public onlyRevoker {
        if (req == bytes32(uint256(OP_SET_REVOKER))) {
            revert OwnerOnlyRequest(req);
        }
        revoke(req);
    }

    function revokeNextDelay() public onlyRevoker {
        revoke(bytes32(uint256(OP_SET_DELAY)));
    }

    function revokeNextOperator() public onlyRevoker {
        revoke(bytes32(uint256(OP_SET_OPERATOR)));
    }

    function revokeNextMessenger() public onlyRevoker {
        revoke(bytes32(uint256(OP_SET_MESSENGER)));
    }

    function revokeNextRateLimiter() public onlyRevoker {
        revoke(bytes32(uint256(OP_SET_RATE_LIMITER)));
    }

    function revokeNextRevoker() public onlyOwner {
        revoke(bytes32(uint256(OP_SET_REVOKER)));
    }

    function revokeNextForcedTransferReceiver() public onlyRevoker {
        revoke(bytes32(uint256(OP_SET_FORCED_TRANSFER_RECEIVER)));
    }

    function revokeNextUpgrade() public onlyRevoker {
        etNextUpgradeToAndCall = 0;
        emit NextUpgradeRevoked(nextUpgradeToAndCallDataHash);
    }

    function addToBlockedList(address _user) public onlyOperator {
        isBlocked[_user] = true;
        emit BlockPlaced(_user);
    }

    function removeFromBlockedList(address _user) public onlyOperator {
        isBlocked[_user] = false;
        emit BlockReleased(_user);
    }

    // mint new tokens to 'receiver'
    // note: allows minting to blocked recipient by design
    // note: nonce used off-chain only, no on-chain validation by design
    function mintTo(
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint64 expectedOzPerToken
    ) public onlyOperator whenNotPaused returns (bool) {
        _checkOzPerToken(expectedOzPerToken);

        bytes32 reqHash = keccak256(abi.encode(OP_MINT, receiver, amount, nonce));
        uint64 et = ensureDelay(reqHash, 0);
        if (et == 0) {
            _checkMintBudget(amount);
            mintBudget = (mintBudget - amount).toUint112();
            _mint(receiver, amount);
            return true;
        } else {
            emit MintRequest(receiver, amount, nonce);
            return false;
        }
    }

    // redeem tokens owned by operator
    // note: allows redeeming for blocked customer by design
    function redeem(
        uint256 amount,
        address customer,
        uint64 expectedOzPerToken,
        bytes calldata data
    ) public onlyOperator whenNotPaused {
        _checkOzPerToken(expectedOzPerToken);
        _burn(operator, amount);
        emit Redeem(customer, amount, data);
        mintBudget += amount.toUint112();
    }

    // note: allows transfer to blocked recipient by design
    function transfer(
        address _recipient,
        uint256 _amount
    ) public virtual override onlyNotBlocked whenNotPaused returns (bool) {
        if (_recipient == address(this)) {
            revert TransferToContract();
        }
        return super.transfer(_recipient, _amount);
    }

    // note: allows transfer to blocked recipient by design
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public virtual override onlyNotBlocked whenNotPaused returns (bool) {
        if (_recipient == address(this)) {
            revert TransferToContract();
        }
        _checkBlocked(_sender);
        return super.transferFrom(_sender, _recipient, _amount);
    }

    // note: allows transfer to blocked recipient by design
    function multiTransfer(
        address[] calldata _recipients,
        uint256[] calldata _values
    ) public {
        if (_recipients.length != _values.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            transfer(_recipients[i], _values[i]);
        }
    }

    // forced transfer by owner; two-call delayed pattern (same as mintTo)
    function forcedTransfer(
        address _from, // must be blocked
        address _to,   // must be forcedTransferReceiver
        uint256 _value,
        uint256 _nonce,
        bytes calldata _data,
        bytes calldata _extraData
    ) external onlyOwner {
        if (!isBlocked[_from]) {
            revert NotBlocked(_from);
        }
        if (_to != forcedTransferReceiver) {
            revert InvalidForcedTransferReceiver(_to);
        }

        bytes32 reqHash = keccak256(abi.encode(OP_FORCED_TRANSFER, _from, _to, _value, _data, _extraData, _nonce));
        uint64 et = ensureDelay(reqHash, 0);
        if (et == 0) {
            _transfer(_from, _to, _value);
            emit ForcedTransfer(_from, _to, _value, _data, _extraData);
        } else {
            emit ForcedTransferRequest(_from, _to, _value, _data, _extraData);
        }
    }

    //-------------

    // get cross-chain message to estimate cross-chain fees
    function msgOfCcSendToken(
        address sender,
        bytes calldata receiverBytes,
        uint256 value
    ) public view returns (bytes memory message) {
        _checkBlocked(sender);
        // note: blocked receiver only checked for EVM chains by design
        if (receiverBytes.length == 20) {
            address receiver = address(bytes20(receiverBytes));
            _checkBlocked(receiver);
        }
        bytes memory senderBytes = abi.encodePacked(sender);
        bytes memory body = abi.encode(senderBytes, receiverBytes, value);
        return abi.encode(TAG_SEND_TOKEN, body);
    }

    // called by the messenger contract to initialize a cross-chain token transfer
    function ccSendToken(
        address sender,
        bytes calldata receiver,
        uint256 value
    ) public onlyMessenger whenNotPaused returns (bytes memory message) {
        if (disableCcSend) {
            revert CcSendDisabled();
        }
        _checkZeroValue(value);
        _burn(sender, value);
        emit CCSendToken(sender, receiver, value);
        return msgOfCcSendToken(sender, receiver, value);
    }

    function msgOfCcSendMintBudget(
        uint112 value
    ) public view returns (bytes memory message) {
        _checkMintBudget(value);
        return abi.encode(TAG_SEND_MINT_BUDGET, abi.encode(value));
    }

    // called by the messenger contract to initialize a cross-chain mint-budget transfer
    // caller is passed explicitly by the messenger (its own msg.sender) so the operator
    // check avoids tx.origin, which breaks account-abstraction and is phishing-prone
    function ccSendMintBudget(
        uint112 value,
        address caller
    ) public onlyMessenger whenNotPaused returns (bytes memory message) {
        _checkOperator(caller);
        _checkZeroValue(value);
        message = msgOfCcSendMintBudget(value);
        mintBudget -= value;
        emit CCSendMintBudget(value);
    }

    // finish a cross-chain token transfer
    // note: mints tokens without checking chain's mintBudget; it is by design
    // that a chain's totalSupply can exceed its mintBudget via cross-chain transfers
    // note: allows minting to blocked receiver by design
    function ccReceiveToken(bytes memory message) internal {
        (bytes memory senderBytes, bytes memory receiverBytes, uint256 value) = abi
            .decode(message, (bytes, bytes, uint256));
        if (receiverBytes.length != 20) {
            revert InvalidReceiver(receiverBytes.length);
        }
        address receiver = address(bytes20(receiverBytes));
        if (rateLimiter == address(0) ||
                IMTokenRateLimiter(rateLimiter).checkAndUpdateRateLimit(receiver, value, senderBytes)) {

            _mint(receiver, value);
            emit CCReceiveToken(senderBytes, receiver, value);
        } else {
            // Message is queued by the RateLimiter logic, and an event is emitted.
        }
    }

    // finish a cross-chain mint-budget transfer
    function ccReceiveMintBudget(bytes memory message) internal {
        uint112 value = abi.decode(message, (uint112));
        mintBudget += value;
        emit CCReceiveMintBudget(value);
    }

    // called by the messenger contract to handle a received cross-chain message
    function ccReceive(bytes calldata message) public onlyMessenger {
        (uint256 tag, bytes memory data) = abi.decode(message, (uint256, bytes));
        if (tag == TAG_SEND_TOKEN) {
            ccReceiveToken(data);
        } else if (tag == TAG_SEND_MINT_BUDGET) {
            ccReceiveMintBudget(data);
        } else {
            revert InvalidMsg(tag);
        }
    }

    //-------------
    // when cross-chain bridge is not available,
    // we can use these functions to manually send and receive mint budget

    function ccSendMintBudgetManually(uint112 value) public onlyOperator {
        _checkZeroValue(value);
        _checkMintBudget(value);
        mintBudget -= value;
        emit CCSendMintBudgetManually(value);
    }

    function ccReceiveMintBudgetManually(uint112 value) public onlyOperator {
        mintBudget += value;
        emit CCReceiveMintBudgetManually(value);
    }

    // Process a batch of queued rate-limited cross-chain token messages.
    // note: if any single index reverts (e.g. invalid/already-deleted slot), the entire batch reverts.
    // Callers must exclude problematic indices and submit them separately or discard them.
    function ccBatchProcessRateLimitedMsgs(uint256[] calldata indices) public {
        for (uint256 i = 0; i < indices.length; i++) {
            ccProcessRateLimitedMsg(indices[i]);
        }
    }

    // manually deliver a queued rate-limited cross-chain token message
    // note: allows minting to blocked receiver by design (same as ccReceiveToken)
    function ccProcessRateLimitedMsg(uint256 index) public onlyOperator {
        (address receiver, uint256 value, bytes memory sender) = IMTokenRateLimiter(rateLimiter).removeRateLimitedMsg(index);
        _mint(receiver, value);
        emit CCReceiveToken(sender, receiver, value);
        emit RateLimitedMsgProcessed(index);
    }

    // Permanently discard a batch of queued rate-limited cross-chain token messages.
    function ccBatchDiscardRateLimitedMsgs(uint256[] calldata indices) public {
        for (uint256 i = 0; i < indices.length; i++) {
            ccDiscardRateLimitedMsg(indices[i]);
        }
    }

    // Permanently discard a queued RateLimited cross-chain token message.
    // Use this when the queued message is identified as malicious (e.g. forged by an attacker)
    // and should never be delivered. No tokens are minted.
    function ccDiscardRateLimitedMsg(uint256 index) public onlyOperator {
        IMTokenRateLimiter(rateLimiter).removeRateLimitedMsg(index);
        emit RateLimitedMsgDiscarded(index);
    }

}
