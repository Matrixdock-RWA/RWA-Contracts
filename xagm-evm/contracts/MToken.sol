// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";
import {IMTokenRateLimiter} from "./interfaces/IMTokenRateLimiter.sol";
// import "hardhat/console.sol";

abstract contract MTokenBase is ERC20PermitUpgradeable, DelayedUpgradeable {

    // per-chain watermarks for cross-chain mintBudget moves: cumulative totals, so a call
    // states the new total and the contract diffs out the delta — a replay reverts instead
    // of applying twice. MTokenMain keys these by the peer chain's eid and so holds one entry
    // per peer; MTokenSide keys them by its own eid and so holds exactly one. Both name the
    // same quantity identically, so the two ends reconcile field to field. The enabled flag
    // is MTokenMain's peer allowlist and is never read on MTokenSide.
    struct MintBudgetInfo {
        bool enabled;
        uint112 totalAllocatedAmount;
        uint112 totalReturnedAmount;
    }

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

    // dead slot — preserved for upgradeable storage layout
    mapping(bytes32 requestHash => uint256 requestInfo) private __requestMap;

    // suspicious accounts can be blocked
    mapping(address account => bool blocked) public isBlocked;

    bool public ccSendDisabled;

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

    // global mintBudget management
    address public mintBudgetSubmitter;
    mapping(uint32 eid => MintBudgetInfo) public mintBudgetMap;
    uint32 public localEid; // this chain's own eid, configured via setLocalEid

}

/*
 Operation                | Initiator  | Timelock | Revoker        | Executor
--------------------------+------------+----------+----------------+----------
transferOwnership         | Owner      | govDelay | Owner/Revoker  | NewOwner
setGovDelay               | Owner      | govDelay | Owner/Revoker  | Initiator
upgrade                   | Owner      | govDelay | Owner/Revoker  | Initiator
setDelay                  | Owner      | govDelay | Owner/Revoker  | Initiator
setMessenger              | Owner      | govDelay | Owner/Revoker  | Initiator
setReserveFeed            | Owner      | govDelay | Owner/Revoker  | Initiator
setFallbackFeed           | Owner      | govDelay | Owner/Revoker  | Initiator
setRateLimiter            | Owner      | govDelay | Owner/Revoker  | Initiator
setForcedTransferReceiver | Owner      | govDelay | Owner/Revoker  | Initiator
setFeeCollector           | Owner      | govDelay | Owner/Revoker  | Initiator
setMintBudgetSubmitter    | Owner      | govDelay | Owner/Revoker  | Initiator
setRevoker                | Owner      | govDelay | Owner/Operator | NewRevoker
setOperator               | Owner      | delay    | Owner/Revoker  | Initiator
unpause                   | Owner      | delay    | Owner/Revoker  | Initiator
enableCcSend              | Owner      | delay    | Owner/Revoker  | Initiator
forcedTransfer            | Owner      | delay    | Owner/Revoker  | Initiator
mintTo                    | Operator   | delay    | Owner/Revoker  | Initiator
ccProcessRateLimitedMsg   | Operator   | delay    | Owner/Revoker  | Initiator
ccDiscardRateLimitedMsg   | Operator   | delay    | Owner/Revoker  | Initiator
setLocalEid               | Owner      | no       | no             | no
pause                     | Operator   | no       | no             | no
disableCcSend             | Operator   | no       | no             | no
addToBlockedList          | Operator   | no       | no             | no
removeFromBlockedList     | Operator   | no       | no             | no
 */

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCClient {
    using SafeCast for uint256;

    uint256 constant TAG_SEND_TOKEN = 2;

    // generous upper bound: the longest tx identifier in use is Solana's 64-byte
    // signature, and the check only exists to keep an unbounded blob out of calldata
    uint256 constant MAX_SRC_TX_HASH_LEN = 128;

    uint64 constant SECONDS_PER_DAY = 24 * 3600; // lastReconcileTime & ozPerTokenBaseTime are rounded to daily boundary
    uint64 constant DAYS_PER_YEAR = 365; // dailyFeeRate is annualFeeRate / DAYS_PER_YEAR
    uint64 constant FEE_RATE_BASE = 10 ** 9; // feeRate is 9 decimals
    uint64 constant OZ_RATIO_BASE = 10 ** 9; // ozPerToken is 9 decimals
    uint64 constant MAX_ANNUAL_FEE_RATE = FEE_RATE_BASE / 10; // 10%

    // delayed operations
    bytes32 constant OP_SET_MESSENGER                = keccak256("OP_SET_MESSENGER");                // 0x6191f37f4e4baceabac34d155232d1c835c833250f9177d97031ad1d289b72c2
    bytes32 constant OP_SET_RESERVE_FEED             = keccak256("OP_SET_RESERVE_FEED");             // 0x63d9e7208cc39149a1247370958483d5782afd0034985f3a1875e4d4d996a1e3
    bytes32 constant OP_SET_FALLBACK_FEED            = keccak256("OP_SET_FALLBACK_FEED");            // 0x833af6d22eb8d2c5cf1ffbc6fc7167919d127fcfcb1200cc8d10a71b91c52212
    bytes32 constant OP_SET_RATE_LIMITER             = keccak256("OP_SET_RATE_LIMITER");             // 0xed798457379d2f20a4c7977521ad2c86cb7507c8854b8ed957ce4eefdb54d695
    bytes32 constant OP_SET_FORCED_TRANSFER_RECEIVER = keccak256("OP_SET_FORCED_TRANSFER_RECEIVER"); // 0x85fa3f3a2a8a9e215053c0fa81064c17bba62c8bc75114f1c6efebbc809b9395
    bytes32 constant OP_SET_FEE_COLLECTOR            = keccak256("OP_SET_FEE_COLLECTOR");            // 0x5fce929af8ba9add31f60f79948e01faec04215045e21ffe8284dc2340bb0717
    bytes32 constant OP_SET_MINT_BUDGET_SUBMITTER    = keccak256("OP_SET_MINT_BUDGET_SUBMITTER");    // 0xf37c63085900270b58e5528f9f20f93604548843368d6de8a65f3e5fe290d1b8
    bytes32 constant OP_ENABLE_CC_SEND               = keccak256("OP_ENABLE_CC_SEND");               // 0x55c10731fa798db7b348dc2a315fbefd2f566460cff39a69411ef19b2c82a5e7
    bytes32 constant OP_UNPAUSE                      = keccak256("OP_UNPAUSE");                      // 0x19aebff3bbcef323e5c760a3ed420922e4d158f9d2c6e69bda4f540960d86e97
    bytes32 constant OP_CC_PROCESS_RATE_LIMITED_MSG  = keccak256("OP_CC_PROCESS_RATE_LIMITED_MSG");  // 0x81e6015855d4c8f939048e3993d674969d59fa69958ee3faff23afeb0e5ce58d
    bytes32 constant OP_CC_DISCARD_RATE_LIMITED_MSG  = keccak256("OP_CC_DISCARD_RATE_LIMITED_MSG");  // 0x22b4483527e4f6d017f96b7dbe00af387783d2ee104e87c1aaadeb61728b5ade
    bytes32 constant OP_FORCED_TRANSFER              = keccak256("OP_FORCED_TRANSFER");              // 0xf7167abf85ccefccadcb37f4a49a61eb06a3d3f90974234c173883e381affde5

    event BlockPlaced(address indexed _user);
    event BlockReleased(address indexed _user);
    event CCSendToken(address indexed sender, bytes receiver, uint256 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint256 value);
    event Redeem(address indexed customer, uint256 amount, bytes data);
    event MintRequest(address indexed receiver, uint256 amount, uint256 nonce);
    event Paused(address indexed _userAddress);
    event Unpaused(address indexed _userAddress); // intentionally named Unpaused (not UnpauseEffected) to match ERC3643
    event DisableCcSend();
    event EnableCcSend();
    event ForcedTransfer(
        address indexed _from,
        address indexed _to,
        uint256 _value,
        bytes _data,
        bytes _operatorData
    );
    event UpdateAnnualFeeRate(
        uint64 newAnnualFeeRate,
        uint64 newOzPerTokenBase,
        uint64 roundedUpdateTime
    );

    error BlockedAccount(address);
    error NotBlocked(address);
    error NotMessenger(address);
    error NotMintBudgetSubmitter(address);
    error OperatorSubmitterConflict(address);
    error MintBudgetNotEnough(uint256 budget, uint256 amount);
    error StaleMintBudgetSubmission(uint112 recorded, uint112 submitted);
    error InvalidSrcTxHash(uint256 length);
    error TransferToContract();
    error ZeroValue();
    error CcSendDisabled();
    error CcSendNotDisabled();
    error InvalidMsg(uint256 tag);
    error InvalidReceiver(uint256 length);
    error AnnualFeeRateTooLarge();
    error OzPerTokenBaseTooLarge();
    error UnexpectedOzPerToken(uint64 expectedOzPerToken, uint64 actualOzPerToken);
    error GlobalPaused();
    error NotPaused();
    error PendingRateLimitedMsgsExist();
    error InvalidForcedTransferReceiver(address);

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

    modifier onlyOwnerOrRevoker() {
        if (msg.sender != revoker && msg.sender != owner()) {
            revert NotOwnerOrRevoker(msg.sender);
        }
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != operator && msg.sender != owner()) {
            revert NotOwnerOrOperator(msg.sender);
        }
        _;
    }

    modifier onlyMessenger() {
        if (msg.sender != messenger) {
            revert NotMessenger(msg.sender);
        }
        _;
    }

    modifier onlyMintBudgetSubmitter() {
        if (msg.sender != mintBudgetSubmitter) {
            revert NotMintBudgetSubmitter(msg.sender);
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

    function _checkMintBudget(uint256 amount) internal view {
        if (amount > mintBudget) {
            revert MintBudgetNotEnough(mintBudget, amount);
        }
    }

    // the submitter credits mintBudget and the operator spends it, so one key holding both
    // roles could walk credit -> mint alone; both setters enforce the split, on each call.
    function _checkOperatorSubmitterDistinct(address _operator, address _submitter) private pure {
        if (_operator == _submitter) {
            revert OperatorSubmitterConflict(_operator);
        }
    }

    // the source-chain tx that authorized a mintBudget submission: variable-length because
    // chains disagree on tx id size (32 bytes on EVM/Sui/Stellar, 64 on Solana), and only
    // recorded — the contract can't read another chain, so verification is off-chain.
    function _checkSrcTxHash(bytes calldata srcTxHash) internal pure {
        if (srcTxHash.length == 0 || srcTxHash.length > MAX_SRC_TX_HASH_LEN) {
            revert InvalidSrcTxHash(srcTxHash.length);
        }
    }

    // monotonic advance of one watermark, shared by the four mintBudget entry points. Two
    // functions because Solidity has no storage pointer to a value-type member, so the field
    // can't be parameterised. The write precedes the callers' later checks — a revert undoes it.
    function _advanceAllocated(
        MintBudgetInfo storage mbInfo,
        uint112 newTotal
    ) internal returns (uint112 deltaAmount) {
        uint112 curr = mbInfo.totalAllocatedAmount;
        if (curr >= newTotal) {
            revert StaleMintBudgetSubmission(curr, newTotal);
        }
        mbInfo.totalAllocatedAmount = newTotal;
        return newTotal - curr;
    }

    function _advanceReturned(
        MintBudgetInfo storage mbInfo,
        uint112 newTotal
    ) internal returns (uint112 deltaAmount) {
        uint112 curr = mbInfo.totalReturnedAmount;
        if (curr >= newTotal) {
            revert StaleMintBudgetSubmission(curr, newTotal);
        }
        mbInfo.totalReturnedAmount = newTotal;
        return newTotal - curr;
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

    /*
    Note: govDelay/delay are deliberately initialized to 0 (delayed ops execute immediately)
    so the deployer can complete wiring and ownership handover without waiting.
    */
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
        __TimeLockerUpgradeable_init_unchained();
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

    function disableCcSend() public onlyOperator {
        // clear any pending enableCcSend request so it cannot outlive this
        // disable: a request pre-planted (or matured during a previous disable)
        // must not be executable right after a new emergency disable, which
        // would bypass the enable delay window entirely
        revoke(OP_ENABLE_CC_SEND);
        ccSendDisabled = true;
        emit DisableCcSend();
    }

    function enableCcSend() public onlyOwner {
        // an enable request may only be created (and executed) while cc-send is
        // actually disabled — otherwise the owner could pre-plant a matured
        // request during normal operation and instantly defeat a future
        // emergency disable
        if (!ccSendDisabled) {
            revert CcSendNotDisabled();
        }
        if (ensureDelay(OP_ENABLE_CC_SEND, 0, 0, delay)) {
            ccSendDisabled = false;
            emit EnableCcSend();
        }
    }

    function pause() external onlyOperator {
        // clear any pending unpause request so it cannot outlive this pause:
        // a request pre-planted (or matured during a previous pause) must not
        // be executable right after a new emergency pause, which would bypass
        // the unpause delay window entirely
        revoke(OP_UNPAUSE);
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        // an unpause request may only be created (and executed) while actually
        // paused — otherwise the owner could pre-plant a matured request during
        // normal operation and instantly defeat a future emergency pause
        if (!paused) {
            revert NotPaused();
        }
        if (ensureDelay(OP_UNPAUSE, 0, 0, delay)) {
            paused = false;
            emit Unpaused(msg.sender);
        }
    }

    function setDelay(uint64 _delay) public onlyOwner {
        checkDelay(_delay);
        if (ensureGovDelay(OP_SET_DELAY, delay, _delay)) {
            delay = _delay;
        }
    }

    function setMessenger(address _messenger) public onlyOwner {
        _checkZeroAddress(_messenger);
        if (ensureGovDelay(OP_SET_MESSENGER, uint160(messenger), uint160(_messenger))) {
            messenger = _messenger;
        }
    }

    // note: allows setting rateLimiter to zero address by design
    function setRateLimiter(address _rateLimiter) public onlyOwner {
        // _checkZeroAddress(_rateLimiter);
        if (ensureGovDelay(OP_SET_RATE_LIMITER, uint160(rateLimiter), uint160(_rateLimiter))) {
            // The old rate limiter's queue can only be drained through this MToken
            // (removeRateLimitedMsg is onlyMToken). Refuse to detach/replace it while
            // messages are still queued, otherwise those tokens would be orphaned.
            // Process or discard all pending messages first.
            address oldRateLimiter = rateLimiter;
            if (oldRateLimiter != address(0) && IMTokenRateLimiter(oldRateLimiter).hasPendingMsgs()) {
                revert PendingRateLimitedMsgsExist();
            }
            rateLimiter = _rateLimiter;
        }
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

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        _checkOperatorSubmitterDistinct(_operator, mintBudgetSubmitter);
        if (ensureDelay(OP_SET_OPERATOR, uint160(operator), uint160(_operator), delay)) {
            operator = _operator;
        }
    }

    function setForcedTransferReceiver(address _receiver) public onlyOwner {
        _checkZeroAddress(_receiver);
        if (ensureGovDelay(OP_SET_FORCED_TRANSFER_RECEIVER, uint160(forcedTransferReceiver), uint160(_receiver))) {
            forcedTransferReceiver = _receiver;
        }
    }

    function setMintBudgetSubmitter(address _submitter) public onlyOwner {
        _checkZeroAddress(_submitter);
        _checkOperatorSubmitterDistinct(operator, _submitter);
        if (ensureGovDelay(OP_SET_MINT_BUDGET_SUBMITTER, uint160(mintBudgetSubmitter), uint160(_submitter))) {
            mintBudgetSubmitter = _submitter;
        }
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function revokeNextGovDelay() public override onlyOwnerOrRevoker {
        _revokeNextGovDelay();
    }

    function revokeOwnershipTransfer() public override onlyOwnerOrRevoker {
        _revokeOwnershipTransfer();
    }

    // Unified revoke entry point — replaces the individual revokeNext* functions that were
    // removed to stay within the contract size limit. Pass any delayed-op key (OP_* constant
    // or a per-request hash) to cancel it. OP_SET_REVOKER is explicitly excluded: use the
    // dedicated revokeNextRevoker() instead (it requires onlyOwnerOrOperator, not onlyOwnerOrRevoker).
    function revokeRequest(bytes32 req) public onlyOwnerOrRevoker {
        if (req == OP_SET_REVOKER) {
            revert NotOwnerOrOperator(msg.sender);
        }
        revoke(req);
    }

    function revokeNextRevoker() public onlyOwnerOrOperator {
        revoke(OP_SET_REVOKER);
    }

    function revokeNextUpgrade() public override onlyOwnerOrRevoker {
        _revokeNextUpgrade();
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

        bytes32 reqHash = keccak256(abi.encode(receiver, amount, nonce));
        if (ensureDelay(reqHash, 0, 0, delay)) {
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

        bytes memory data = abi.encode(_from, _to, _value, _nonce, _data, _extraData);
        bytes32 reqHash = keccak256(abi.encode(OP_FORCED_TRANSFER, data));
        if (ensureDelay(reqHash, 0, 0, delay)) {
            _transfer(_from, _to, _value);
            emit ForcedTransfer(_from, _to, _value, _data, _extraData);
        } else {
            emit DelayedOpExtraData(reqHash, OP_FORCED_TRANSFER, data);
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
        if (ccSendDisabled) {
            revert CcSendDisabled();
        }
        _checkZeroValue(value);
        _burn(sender, value);
        emit CCSendToken(sender, receiver, value);
        return msgOfCcSendToken(sender, receiver, value);
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

    // called by the messenger contract to handle a received cross-chain message
    function ccReceive(bytes calldata message) public onlyMessenger {
        (uint256 tag, bytes memory data) = abi.decode(message, (uint256, bytes));
        if (tag == TAG_SEND_TOKEN) {
            ccReceiveToken(data);
        } else {
            revert InvalidMsg(tag);
        }
    }

    // manually deliver a queued rate-limited message; delayed via `delay`, and mints to a
    // blocked receiver by design (same as ccReceiveToken). reqHash binds `rateLimiter` so a
    // request can't mature against a same-numbered message in a replacement one, and the
    // existence check stops pre-maturing a request for an index nothing has queued yet.
    function ccProcessRateLimitedMsg(uint256 index) public onlyOperator whenNotPaused {
        IMTokenRateLimiter(rateLimiter).checkRateLimitedMsg(index);
        bytes32 reqHash = keccak256(abi.encode(OP_CC_PROCESS_RATE_LIMITED_MSG, rateLimiter, index));
        if (ensureDelay(reqHash, 0, uint160(index), delay)) {
            (address receiver, uint256 value, bytes memory sender) = IMTokenRateLimiter(rateLimiter).removeRateLimitedMsg(index);
            _mint(receiver, value);
            emit CCReceiveToken(sender, receiver, value);
        }
    }

    // Permanently discard a queued RateLimited cross-chain token message.
    // Use this when the queued message is identified as malicious (e.g. forged by an attacker)
    // and should never be delivered. No tokens are minted.
    // delayed via the normal `delay` (two-call pattern, same as mintTo); see
    // ccProcessRateLimitedMsg for why reqHash binds rateLimiter + requires existence.
    function ccDiscardRateLimitedMsg(uint256 index) public onlyOperator {
        IMTokenRateLimiter(rateLimiter).checkRateLimitedMsg(index);
        bytes32 reqHash = keccak256(abi.encode(OP_CC_DISCARD_RATE_LIMITED_MSG, rateLimiter, index));
        if (ensureDelay(reqHash, 0, uint160(index), delay)) {
            IMTokenRateLimiter(rateLimiter).removeRateLimitedMsg(index);
        }
    }

}
