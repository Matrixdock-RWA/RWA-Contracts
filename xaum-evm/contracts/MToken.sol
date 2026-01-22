// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";
// import "hardhat/console.sol";

abstract contract MTokenBase is ERC20PermitUpgradeable, DelayedUpgradeable {
    // every chain has its own mintBudget, operator can move mintBudget from one chain to another
    uint112 public mintBudget;

    // sensitive operation must be delayed before taking effect
    uint64 public delay;
    uint64 public nextDelay;
    uint64 public etNextDelay; //effective time

    // the operator takes care of everyday operations
    address public operator;
    address public nextOperator;
    uint64 public etNextOperator; //effective time

    // a revoker can delete delayed operations before they taking effect
    address public revoker;
    address public nextRevoker;
    uint64 public etNextRevoker; //effective time

    // the messenger contract takes care of cross-chain task
    address public messenger;
    address public nextMessenger;
    uint64 public etNextMessenger; //effective time

    // the delayed minting requests are stored in requestMap
    mapping(bytes32 requestHash => uint effectiveTime) public requestMap;

    // the gold NFT contract for bullions
    address public nftContract;

    // suspicious accounts can be blocked
    mapping(address account => bool blocked) public isBlocked;

    bool public disableCcSend;

    /* Main Chain */

    // usedReserve = Sum of each chain's totalSupply and mintBudget
    // usedReserve <= Chainlink's PoR
    uint112 public usedReserve;

    // ChainLink PoR
    address public reserveFeed;
    address public nextReserveFeed;
    uint64 public etNextReserveFeed; //effective time
    address public fallbackFeed;
    address public nextFallbackFeed;
    uint64 public etNextFallbackFeed; //effective time
}

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCClient {
    using SafeCast for uint;

    uint64 constant MIN_DELAY = 1 hours;
    uint64 constant MAX_DELAY = 48 hours;

    uint constant TAG_SEND_TOKEN = 2;
    uint constant TAG_SEND_MINT_BUDGET = 3;

    uint8 constant LOCAL_DECIMALS = 18;
    uint8 constant SHARED_DECIMALS = 9;
    uint256 constant DECIMALS_SCALE_FACTOR =
        10 ** (LOCAL_DECIMALS - SHARED_DECIMALS);

    event SetDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetDelayEffected(uint64 newDelay);
    event SetOperatorRequest(address oldAddr, address newAddr, uint64 et);
    event SetOperatorEffected(address newAddr);
    event SetRevokerRequest(address oldAddr, address newAddr, uint64 et);
    event SetRevokerEffected(address newAddr);
    event SetMessengerRequest(address oldAddr, address newAddr, uint64 et);
    event SetMessengerEffected(address newAddr);
    event BlockPlaced(address indexed _user);
    event BlockReleased(address indexed _user);
    event CCSendToken(address indexed sender, bytes receiver, uint value);
    event CCSendMintBudget(uint112 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint value);
    event CCReceiveMintBudget(uint112 value);
    event Redeem(address indexed customer, uint amount, bytes data);
    event MintRequest(address indexed receiver, uint amount, uint nonce);
    event RequestRevoked(bytes32 indexed req);

    error BlockedAccount(address);
    error NotOperator(address);
    error NotRevoker(address);
    error NotNftContract(address);
    error NotMessenger(address);
    error NotOperatorNorNft(address);
    error MintBudgetNotEnough(uint budget, uint amount);
    error TransferToContract();
    error ZeroValue();
    error ArgsMismatch();
    error TooEarlyToExecute(address receiver, uint amount, uint nonce);
    error CcSendDisabled();
    error InvalidMsg(uint tag);
    error DelayTooSmall();
    error DelayTooLarge();
    error InvalidReceiver(uint length);
    error PrecisionLost();

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

    function _checkMintBudget(uint amount) private view {
        if (amount > mintBudget) {
            revert MintBudgetNotEnough(mintBudget, amount);
        }
    }

    function _checkZeroValue(uint value) private pure {
        if (value == 0) {
            revert ZeroValue();
        }
    }

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
        operator = _operator;
    }

    function setDisableCcSend(bool b) public onlyOwner {
        disableCcSend = b;
    }

    function setDelay(uint64 _delay) public onlyOwner {
        if (_delay < MIN_DELAY) {
            revert DelayTooSmall();
        }
        if (_delay > MAX_DELAY) {
            revert DelayTooLarge();
        }

        uint64 et = etNextDelay;
        if (_delay == nextDelay && et != 0 && et < block.timestamp) {
            delay = _delay;
            emit SetDelayEffected(_delay);
        } else {
            nextDelay = _delay;
            etNextDelay = uint64(block.timestamp) + delay;
            emit SetDelayRequest(delay, _delay, etNextDelay);
        }
    }

    function setMessenger(address _messenger) public onlyOwner {
        _checkZeroAddress(_messenger);
        uint64 et = etNextMessenger;
        if (_messenger == nextMessenger && et != 0 && et < block.timestamp) {
            messenger = _messenger;
            emit SetMessengerEffected(_messenger);
        } else {
            nextMessenger = _messenger;
            etNextMessenger = uint64(block.timestamp) + delay;
            emit SetMessengerRequest(messenger, _messenger, etNextMessenger);
        }
    }

    // init nftContract. can only be called once
    function setNFTContract(address _nftContract) public onlyOwner {
        _checkZeroAddress(_nftContract);
        if (nftContract == address(0)) {
            nftContract = _nftContract;
        }
    }

    function setRevoker(address _revoker) public onlyOwner {
        _checkZeroAddress(_revoker);
        uint64 et = etNextRevoker;
        if (_revoker == nextRevoker && et != 0 && et < block.timestamp) {
            revoker = _revoker;
            emit SetRevokerEffected(_revoker);
        } else {
            nextRevoker = _revoker;
            etNextRevoker = uint64(block.timestamp) + delay;
            emit SetRevokerRequest(revoker, _revoker, etNextRevoker);
        }
    }

    function setOperator(address _operator) public onlyOwner {
        _checkZeroAddress(_operator);
        uint64 et = etNextOperator;
        if (_operator == nextOperator && et != 0 && et < block.timestamp) {
            operator = _operator;
            emit SetOperatorEffected(_operator);
        } else {
            nextOperator = _operator;
            etNextOperator = uint64(block.timestamp) + delay;
            emit SetOperatorRequest(operator, _operator, etNextOperator);
        }
    }

    function getDelay() internal view override returns (uint64) {
        return delay;
    }

    function revokeRequest(bytes32 req) public onlyRevoker {
        delete requestMap[req];
        emit RequestRevoked(req);
    }

    function revokeNextDelay() public onlyRevoker {
        etNextDelay = 0;
    }

    function revokeNextOperator() public onlyRevoker {
        etNextOperator = 0;
    }

    function revokeNextMessenger() public onlyRevoker {
        etNextMessenger = 0;
    }

    function revokeNextRevoker() public onlyOwner {
        etNextRevoker = 0;
    }

    function revokeNextUpgrade() public onlyRevoker {
        etNextUpgradeToAndCall = 0;
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
    function pack(address tokenOwner, uint amount) public onlyNFTContract {
        _transfer(tokenOwner, msg.sender, amount);
    }

    // NFT Contract unpacks a NFT and return the tokens to tokenOwner
    function unpack(address tokenOwner, uint amount) public onlyNFTContract {
        _transfer(msg.sender, tokenOwner, amount);
    }

    // mint new tokens to 'receiver'
    function mintTo(
        address receiver,
        uint amount,
        uint nonce
    ) public onlyOperatorAndNft returns (bool) {
        bytes32 req = keccak256(abi.encode(receiver, amount, nonce));
        uint et = requestMap[req];
        if (et == 0) {
            // add a record for this mint-request and exit
            requestMap[req] = block.timestamp + delay;
            emit MintRequest(receiver, amount, nonce);
            return false;
        } else {
            if (et < block.timestamp) {
                delete requestMap[req]; // clear the record
            } else {
                revert TooEarlyToExecute(receiver, amount, nonce);
            }
        }
        _checkMintBudget(amount);
        mintBudget = (mintBudget - amount).toUint112();
        _mint(receiver, amount);
        return true;
    }

    // redeem tokens owned by operator
    function redeem(
        uint amount,
        address customer,
        bytes calldata data
    ) public onlyOperatorAndNft {
        _burn(operator, amount);
        emit Redeem(customer, amount, data);
        mintBudget += amount.toUint112();
    }

    function transfer(
        address _recipient,
        uint256 _amount
    ) public virtual override onlyNotBlocked returns (bool) {
        if (_recipient == address(this)) {
            revert TransferToContract();
        }
        return super.transfer(_recipient, _amount);
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public virtual override onlyNotBlocked returns (bool) {
        if (_recipient == address(this)) {
            revert TransferToContract();
        }
        _checkBlocked(_sender);
        return super.transferFrom(_sender, _recipient, _amount);
    }

    function multiTransfer(
        address[] calldata _recipients,
        uint256[] calldata _values
    ) public onlyNotBlocked {
        if (_recipients.length != _values.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            transfer(_recipients[i], _values[i]);
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
    ) public onlyMessenger returns (bytes memory message) {
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
        value = convertToSharedDecimals(value).toUint112();
        return abi.encode(TAG_SEND_MINT_BUDGET, abi.encode(value));
    }

    // called by the messenger contract to initialize a cross-chain mint-budget transfer
    function ccSendMintBudget(
        uint112 value
    ) public onlyMessenger returns (bytes memory message) {
        _checkOperator(tx.origin);
        _checkZeroValue(value);
        message = msgOfCcSendMintBudget(value);
        mintBudget -= value;
        emit CCSendMintBudget(value);
    }

    // finish a cross-chain token transfer
    function ccReceiveToken(bytes memory message) internal {
        (bytes memory senderBytes, bytes memory receiverBytes, uint value) = abi
            .decode(message, (bytes, bytes, uint));
        if (receiverBytes.length != 20) {
            revert InvalidReceiver(receiverBytes.length);
        }
        address receiver = address(bytes20(receiverBytes));
        value = convertToLocalDecimals(value);
        _mint(receiver, value);
        emit CCReceiveToken(senderBytes, receiver, value);
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
        (uint tag, bytes memory data) = abi.decode(message, (uint, bytes));
        if (tag == TAG_SEND_TOKEN) {
            ccReceiveToken(data);
        } else if (tag == TAG_SEND_MINT_BUDGET) {
            ccReceiveMintBudget(data);
        } else {
            revert InvalidMsg(tag);
        }
    }
}
