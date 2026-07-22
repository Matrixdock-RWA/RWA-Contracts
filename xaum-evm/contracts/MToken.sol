// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";
import {IMTokenRateLimiter} from "./interfaces/IMTokenRateLimiter.sol";
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

    // dead slot — preserved for upgradeable storage layout
    mapping(bytes32 requestHash => uint256 requestInfo) private __requestMap;

    // the gold NFT contract for bullions
    address public nftContract;

    // suspicious accounts can be blocked
    mapping(address account => bool blocked) public isBlocked;

    bool public ccSendDisabled;

    // usedReserve = Sum of each chain's totalSupply and mintBudget
    // usedReserve <= Chainlink's PoR
    uint112 public usedReserve;

    // ChainLink PoR
    address public reserveFeed;
    address private __nextReserveFeed; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextReserveFeed; // dead slot — preserved for upgradeable storage layout
    address public fallbackFeed;
    address private __nextFallbackFeed; // dead slot — preserved for upgradeable storage layout
    uint64 private __etNextFallbackFeed; // dead slot — preserved for upgradeable storage layout

    // RateLimiter
    address public rateLimiter;

    // Global pause flag
    bool public paused;

    // the designated receiver for forced transfers of blocked accounts
    address public forcedTransferReceiver;

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
setRevoker                | Owner      | govDelay | Owner/Operator | NewRevoker
setOperator               | Owner      | delay    | Owner/Revoker  | Initiator
unpause                   | Owner      | delay    | Owner/Revoker  | Initiator
enableCcSend              | Owner      | delay    | Owner/Revoker  | Initiator
forcedTransfer            | Owner      | delay    | Owner/Revoker  | Initiator
mintTo                    | Operator   | delay    | Owner/Revoker  | Initiator
pause                     | Operator   | no       | no             | no
disableCcSend             | Operator   | no       | no             | no
addToBlockedList          | Operator   | no       | no             | no
removeFromBlockedList     | Operator   | no       | no             | no
ccProcessRateLimitedMsg   | Operator   | no       | no             | no
ccDiscardRateLimitedMsg   | Operator   | no       | no             | no
 */

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCClient {
    using SafeCast for uint256;

    uint256 constant TAG_SEND_TOKEN = 2;
    uint256 constant TAG_SEND_MINT_BUDGET = 3;

    uint8 constant LOCAL_DECIMALS = 18;
    uint8 constant SHARED_DECIMALS = 9;
    uint256 constant DECIMALS_SCALE_FACTOR =
        10 ** (LOCAL_DECIMALS - SHARED_DECIMALS);

    // delayed operations
    bytes32 constant OP_SET_MESSENGER                = keccak256("OP_SET_MESSENGER");                // 0x6191f37f4e4baceabac34d155232d1c835c833250f9177d97031ad1d289b72c2
    bytes32 constant OP_SET_RESERVE_FEED             = keccak256("OP_SET_RESERVE_FEED");             // 0x63d9e7208cc39149a1247370958483d5782afd0034985f3a1875e4d4d996a1e3
    bytes32 constant OP_SET_FALLBACK_FEED            = keccak256("OP_SET_FALLBACK_FEED");            // 0x833af6d22eb8d2c5cf1ffbc6fc7167919d127fcfcb1200cc8d10a71b91c52212
    bytes32 constant OP_SET_RATE_LIMITER             = keccak256("OP_SET_RATE_LIMITER");             // 0xed798457379d2f20a4c7977521ad2c86cb7507c8854b8ed957ce4eefdb54d695
    bytes32 constant OP_SET_FORCED_TRANSFER_RECEIVER = keccak256("OP_SET_FORCED_TRANSFER_RECEIVER"); // 0x85fa3f3a2a8a9e215053c0fa81064c17bba62c8bc75114f1c6efebbc809b9395
    bytes32 constant OP_ENABLE_CC_SEND               = keccak256("OP_ENABLE_CC_SEND");               // 0x55c10731fa798db7b348dc2a315fbefd2f566460cff39a69411ef19b2c82a5e7
    bytes32 constant OP_UNPAUSE                      = keccak256("OP_UNPAUSE");                      // 0x19aebff3bbcef323e5c760a3ed420922e4d158f9d2c6e69bda4f540960d86e97

    event SetMessengerRequest(address oldAddr, address newAddr, uint64 et);
    event SetMessengerEffected(address newAddr);
    event SetRateLimiterRequest(address oldAddr, address newAddr, uint64 et);
    event SetRateLimiterEffected(address newAddr);
    event SetForcedTransferReceiverRequest(address oldAddr, address newAddr, uint64 et);
    event SetForcedTransferReceiverEffected(address newAddr);
    event EnableCCSendRequest(uint64 et);
    event EnableCCSendEffected();
    event UnpauseRequest(uint64 et);
    event BlockPlaced(address indexed _user);
    event BlockReleased(address indexed _user);
    event CCSendToken(address indexed sender, bytes receiver, uint256 value);
    event CCSendMintBudget(uint112 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint256 value);
    event CCReceiveMintBudget(uint112 value);
    event Redeem(address indexed customer, uint256 amount, bytes data);
    event MintRequest(address indexed receiver, uint256 amount, uint256 nonce);
    event RateLimitedMsgProcessed(uint256 index);
    event RateLimitedMsgDiscarded(uint256 index);
    event Paused(address indexed _userAddress);
    event Unpaused(address indexed _userAddress); // intentionally named Unpaused (not UnpauseEffected) to match ERC3643
    event DisableCcSend();
    event SetNFTContract(address nft);
    event ForcedTransferRequest(
        address indexed _from, 
        address indexed _to, 
        uint256 _value, 
        bytes _data, 
        bytes _operatorData
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
    error NotNftContract(address);
    error NotMessenger(address);
    error NotOperatorNorNft(address);
    error MintBudgetNotEnough(uint256 budget, uint256 amount);
    error TransferToContract();
    error ZeroValue();
    error ArgsMismatch();
    error CcSendDisabled();
    error CcSendNotDisabled();
    error InvalidMsg(uint256 tag);
    error InvalidReceiver(uint256 length);
    error PrecisionLost();
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

    modifier onlyOperatorAndNft() {
        if (msg.sender != operator && msg.sender != nftContract) {
            revert NotOperatorNorNft(msg.sender);
        }
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

    modifier onlyNFTContract() {
        if (msg.sender != nftContract) {
            revert NotNftContract(msg.sender);
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

    function _checkZeroValue(uint256 value) private pure {
        if (value == 0) {
            revert ZeroValue();
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
        address _operator
    ) internal onlyInitializing {
        __ERC20_init_unchained(name, symbol);
        __EIP712_init_unchained(symbol, "1");
        __ERC20Permit_init_unchained(symbol);
        __Ownable_init_unchained(_owner);
        __TimeLockerUpgradeable_init_unchained();
        operator = _operator;
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
        uint64 et = ensureDelay(OP_ENABLE_CC_SEND, 0, delay);
        if (et == 0) {
            ccSendDisabled = false;
            emit EnableCCSendEffected();
        } else {
            emit EnableCCSendRequest(et);
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
        uint64 et = ensureDelay(OP_UNPAUSE, 0, delay);
        if (et == 0) {
            paused = false;
            emit Unpaused(msg.sender);
        } else {
            emit UnpauseRequest(et);
        }
    }

    function setDelay(uint64 _delay) public onlyOwner {
        checkDelay(_delay);
        uint64 et = ensureGovDelay(OP_SET_DELAY, _delay);
        if (et == 0) {
            delay = _delay;
            emit SetDelayEffected(_delay);
        } else {
            emit SetDelayRequest(delay, _delay, et);
        }
    }

    function setMessenger(address _messenger) public onlyOwner {
        _checkZeroAddress(_messenger);
        uint64 et = ensureGovDelay(OP_SET_MESSENGER, uint160(_messenger));
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
        uint64 et = ensureGovDelay(OP_SET_RATE_LIMITER, uint160(_rateLimiter));
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

    // init nftContract. can only be called once
    function setNFTContract(address _nftContract) public onlyOwner {
        _checkZeroAddress(_nftContract);
        if (nftContract == address(0)) {
            nftContract = _nftContract;
            emit SetNFTContract(_nftContract);
        }
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        uint64 et = ensureGovDelay(OP_SET_REVOKER, uint160(_revoker));
        if (et == 0) {
            revert NotNewRevoker(msg.sender);
        }
        emit SetRevokerRequest(revoker, _revoker, et);
    }

    function acceptRevoker() public {
        address newRevoker = msg.sender;
        uint64 et = ensureGovDelay(OP_SET_REVOKER, uint160(newRevoker));
        if (et > 0) {
            revert NoPendingRequest(OP_SET_REVOKER);
        }
        revoker = newRevoker;
        emit SetRevokerEffected(newRevoker);
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        uint64 et = ensureDelay(OP_SET_OPERATOR, uint160(_operator), delay);
        if (et == 0) {
            operator = _operator;
            emit SetOperatorEffected(_operator);
        } else {
            emit SetOperatorRequest(operator, _operator, et);
        }
    }

    function setForcedTransferReceiver(address _receiver) public onlyOwner {
        _checkZeroAddress(_receiver);
        uint64 et = ensureGovDelay(OP_SET_FORCED_TRANSFER_RECEIVER, uint160(_receiver));
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

    // NFT Contract packs tokens into one NFT.
    // note: allows blocked tokenOwner by design
    function pack(address tokenOwner, uint256 amount) public onlyNFTContract whenNotPaused {
        _transfer(tokenOwner, msg.sender, amount);
    }

    // NFT Contract unpacks a NFT and return the tokens to tokenOwner
    // note: allows blocked tokenOwner by design
    function unpack(address tokenOwner, uint256 amount) public onlyNFTContract whenNotPaused {
        _transfer(msg.sender, tokenOwner, amount);
    }

    // mint new tokens to 'receiver'
    // note: allows minting to blocked recipient by design
    // note: nonce used off-chain only, no on-chain validation by design
    function mintTo(
        address receiver,
        uint256 amount,
        uint256 nonce
    ) public onlyOperatorAndNft whenNotPaused returns (bool) {
        bytes32 reqHash = keccak256(abi.encode(receiver, amount, nonce));
        uint64 et = ensureDelay(reqHash, 0, delay);
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
        bytes calldata data
    ) public onlyOperatorAndNft whenNotPaused {
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

        bytes32 reqHash = keccak256(abi.encode(_from, _to, _value, _data, _extraData, _nonce));
        uint64 et = ensureDelay(reqHash, 0, delay);
        if (et == 0) {
            _transfer(_from, _to, _value);
            emit ForcedTransfer(_from, _to, _value, _data, _extraData);
        } else {
            emit ForcedTransferRequest(_from, _to, _value, _data, _extraData);
        }
    }

    //-------------

    function convertToSharedDecimals(
        uint256 value
    ) private pure returns (uint256) {
        if (value % DECIMALS_SCALE_FACTOR != 0) {
            revert PrecisionLost();
        }
        return value / DECIMALS_SCALE_FACTOR;
    }

    function convertToLocalDecimals(
        uint256 value
    ) private pure returns (uint256) {
        return value * DECIMALS_SCALE_FACTOR;
    }

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
        value = convertToSharedDecimals(value);
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

    function msgOfCcSendMintBudget(
        uint112 value
    ) public view returns (bytes memory message) {
        _checkMintBudget(value);
        value = convertToSharedDecimals(value).toUint112();
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
        value = convertToLocalDecimals(value);
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
        value = convertToLocalDecimals(value).toUint112();
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
    function ccProcessRateLimitedMsg(uint256 index) public onlyOperator whenNotPaused {
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
