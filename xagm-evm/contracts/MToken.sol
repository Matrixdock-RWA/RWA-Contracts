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
    mapping(bytes32 requestHash => uint256 effectiveTime) public requestMap;

    // suspicious accounts can be blocked
    mapping(address account => bool blocked) public isBlocked;

    bool public disableCcSend;

    /* Main Chain */

    // totalTokenObligation = Sum of each chain's totalSupply and mintBudget
    // totalTokenObligation * ozPerToken <= Chainlink's PoR
    uint112 public totalTokenObligation;

    // ChainLink PoR
    address public reserveFeed;
    address public nextReserveFeed;
    uint64 public etNextReserveFeed; //effective time
    address public fallbackFeed;
    address public nextFallbackFeed;
    uint64 public etNextFallbackFeed; //effective time

    // the address that collects the fee tokens
    address public feeCollector;
    address public nextFeeCollector;
    uint64 public etNextFeeCollector; //effective time

    uint64 public lastReconcileTime; // timestamp of the last reconcile (fee minting), rounded to daily boundary
    uint64 public ozPerTokenBaseTime; // timestamp of the update of annualFeeRate & ozPerTokenBase, rounded to daily boundary
    uint64 public annualFeeRate; // the annual fee rate, 9 decimals
    uint64 public ozPerTokenBase; // calculated when annualFeeRate is updated, 9 decimals
}

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCClient {
    using SafeCast for uint256;

    uint64 constant MIN_DELAY = 1 hours;
    uint64 constant MAX_DELAY = 48 hours;

    uint256 constant TAG_SEND_TOKEN = 2;
    uint256 constant TAG_SEND_MINT_BUDGET = 3;

    uint64 constant SECONDS_PER_DAY = 24 * 3600; // lastReconcileTime & ozPerTokenBaseTime are rounded to daily boundary
    uint64 constant DAYS_PER_YEAR = 365; // dailyFeeRate is annualFeeRate / DAYS_PER_YEAR
    uint64 constant FEE_RATE_BASE = 10 ** 9; // feeRate is 9 decimals
    uint64 constant OZ_RATIO_BASE = 10 ** 9; // ozPerToken is 9 decimals
    uint64 constant MAX_ANNUAL_FEE_RATE = FEE_RATE_BASE / 10; // 10%

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
    event CCSendToken(address indexed sender, bytes receiver, uint256 value);
    event CCSendMintBudget(uint112 value);
    event CCSendMintBudgetManually(uint112 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint256 value);
    event CCReceiveMintBudget(uint112 value);
    event CCReceiveMintBudgetManually(uint112 value);
    event Redeem(address indexed customer, uint256 amount, bytes data);
    event MintRequest(address indexed receiver, uint256 amount, uint256 nonce);
    event RequestRevoked(bytes32 indexed req);
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
    error NotOperator(address);
    error NotRevoker(address);
    error NotMessenger(address);
    error MintBudgetNotEnough(uint256 budget, uint256 amount);
    error TransferToContract();
    error ZeroValue();
    error ArgsMismatch();
    error TooEarlyToExecute(address receiver, uint256 amount, uint256 nonce);
    error CcSendDisabled();
    error InvalidMsg(uint256 tag);
    error DelayTooSmall();
    error DelayTooLarge();
    error InvalidReceiver(uint256 length);
    error AnnualFeeRateTooLarge();
    error OzPerTokenBaseTooLarge();

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

    function _checkZeroValue(uint256 value) private pure {
        if (value == 0) {
            revert ZeroValue();
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
        // note: missing event to be added in future update
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
            uint64 _currDelay = delay;
            uint64 _etNextDelay = uint64(block.timestamp) + _currDelay;
            nextDelay = _delay;
            etNextDelay = _etNextDelay;
            emit SetDelayRequest(_currDelay, _delay, _etNextDelay);
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
            uint64 _etNextMessenger = uint64(block.timestamp) + delay;
            etNextMessenger = _etNextMessenger;
            emit SetMessengerRequest(messenger, _messenger, _etNextMessenger);
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
            uint64 _etNextRevoker = uint64(block.timestamp) + delay;
            etNextRevoker = _etNextRevoker;
            emit SetRevokerRequest(revoker, _revoker, _etNextRevoker);
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
            uint64 _etNextOperator = uint64(block.timestamp) + delay;
            etNextOperator = _etNextOperator;
            emit SetOperatorRequest(operator, _operator, _etNextOperator);
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
        // note: missing event to be added in future update
        etNextDelay = 0;
    }

    function revokeNextOperator() public onlyRevoker {
        // note: missing event to be added in future update
        etNextOperator = 0;
    }

    function revokeNextMessenger() public onlyRevoker {
        // note: missing event to be added in future update
        etNextMessenger = 0;
    }

    function revokeNextRevoker() public onlyOwner {
        // note: missing event to be added in future update
        etNextRevoker = 0;
    }

    function revokeNextUpgrade() public onlyRevoker {
        // note: missing event to be added in future update
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

    // mint new tokens to 'receiver'
    // note: allows minting to blocked recipient by design
    // note: nonce used off-chain only, no on-chain validation by design
    function mintTo(
        address receiver,
        uint256 amount,
        uint256 nonce
    ) public onlyOperator returns (bool) {
        bytes32 req = keccak256(abi.encode(receiver, amount, nonce));
        uint256 et = requestMap[req];
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
    // note: allows redeeming for blocked customer by design
    function redeem(
        uint256 amount,
        address customer,
        bytes calldata data
    ) public onlyOperator {
        _burn(operator, amount);
        emit Redeem(customer, amount, data);
        mintBudget += amount.toUint112();
    }

    // note: allows transfer to blocked recipient by design
    function transfer(
        address _recipient,
        uint256 _amount
    ) public virtual override onlyNotBlocked returns (bool) {
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
    ) public virtual override onlyNotBlocked returns (bool) {
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
    ) public onlyNotBlocked {
        if (_recipients.length != _values.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            transfer(_recipients[i], _values[i]);
        }
    }

    // forced transfer by owner
    function forcedTransfer(
        address _from,
        address _to,
        uint256 _value,
        bytes calldata _data,
        bytes calldata _extraData
    ) external onlyOwner {
        _transfer(_from, _to, _value);
        emit ForcedTransfer(_from, _to, _value, _data, _extraData);
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
        return abi.encode(TAG_SEND_MINT_BUDGET, abi.encode(value));
    }

    // called by the messenger contract to initialize a cross-chain mint-budget transfer
    function ccSendMintBudget(
        uint112 value
    ) public onlyMessenger returns (bytes memory message) {
        // note: we are very careful with any third-party contracts the operator calls
        // to avoid unintended shuffling of cross-chain mint budgets
        _checkOperator(tx.origin);
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
        _mint(receiver, value);
        emit CCReceiveToken(senderBytes, receiver, value);
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
}
