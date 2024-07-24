// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./MTokenMessager.sol";
// import "hardhat/console.sol";

abstract contract MTokenBase is
    OwnableUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable
{
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

    // the messager contract takes care of cross-chain task
    address public messager;
    address public nextMessager;
    uint64 public etNextMessager; //effective time

    // upgradeToAndCall() is delayed
    address public nextImplementation;
    bytes32 public nextUpgradeToAndCallDataHash;
    uint64 public etNextUpgradeToAndCall; //effective time

    // the delayed minting requests are stored in requestMap
    mapping(bytes32 requestHash => uint effectiveTime) public requestMap;

    // the gold NFT contract for bullions
    address public nftContract;

    // suspicious accounts can be blocked
    mapping(address => bool) public isBlocked;

    bool public disableCcSend;

    /* Main Chain */

    // usedReserve = Sum of each chain's totalSupply and mintBudget
    // usedReserve <= Chainlink's PoR
    uint112 public usedReserve;

    // ChainLink PoR
    address public reserveFeed;
    address public nextReserveFeed;
    uint64 public etNextReserveFeed; //effective time
}

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCIPClient {
    uint constant TagSendToken = 2;
    uint constant TagSendMintBudget = 3;

    event SetDelayRequest(uint64 oldDelay, uint64 newDelay, uint64 et);
    event SetDelayEffected(uint64 newDelay);
    event SetOperatorRequest(address oldAddr, address newAddr, uint64 et);
    event SetOperatorEffected(address newAddr);
    event SetRevokerRequest(address oldAddr, address newAddr, uint64 et);
    event SetRevokerEffected(address newAddr);
    event SetMessagerRequest(address oldAddr, address newAddr, uint64 et);
    event SetMessagerEffected(address newAddr);
    event BlockPlaced(address indexed _user);
    event BlockReleased(address indexed _user);
    event CCSendToken(
        address indexed sender,
        address indexed receiver,
        uint value
    );
    event CCSendMintBudget(uint112 value);
    event CCReceiveToken(
        address indexed sender,
        address indexed receiver,
        uint value
    );
    event CCReceiveMintBudget(uint112 value);
    event Redeem(address indexed customer, uint amount, bytes data);
    event MintRequest(address indexed receiver, uint amount, uint nonce);
    event RequestRevoked(bytes32 indexed req);
    event UpgradeToAndCallRequest(address newImplementation, bytes data);

    error BlockedAccount(address);
    error NotOperator(address);
    error NotRevoker(address);
    error NotNftContract(address);
    error NotMessager(address);
    error NotOperatorNorNft(address);
    error MintBudgetNotEnough(uint budget, uint amount);
    error TransferToContract();
    error ZeroValue();
    error ArgsMismatch();
    error TooEarlyToExecute(address receiver, uint amount, uint nonce);
    error CcSendDisabled();
    error InvalidMsg(uint tag);
    error InvalidUpgradeToAndCallImpl();
    error InvalidUpgradeToAndCallData();
    error TooEarlyToUpgradeToAndCall();

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

    modifier onlyMessager() {
        if (msg.sender != messager) {
            revert NotMessager(msg.sender);
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
        string memory symbol,
        address _owner,
        address _operator
    ) internal onlyInitializing {
        __ERC20_init_unchained(symbol, symbol);
        __EIP712_init_unchained(symbol, "1");
        __ERC20Permit_init_unchained(symbol);
        __Ownable_init_unchained(_owner);
        operator = _operator;
    }

    function setDisableCcSend(bool b) public onlyOwner {
        disableCcSend = b;
    }

    function setDelay(uint64 _delay) public onlyOwner {
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

    function setMessager(address _messager) public onlyOwner {
        uint64 et = etNextMessager;
        if (_messager == nextMessager && et != 0 && et < block.timestamp) {
            messager = _messager;
            emit SetMessagerEffected(_messager);
        } else {
            nextMessager = _messager;
            etNextMessager = uint64(block.timestamp) + delay;
            emit SetMessagerRequest(messager, _messager, etNextMessager);
        }
    }

    // init nftContract. can only be called once
    function setNFTContract(address _nftContract) public onlyOwner {
        if (nftContract == address(0)) {
            nftContract = _nftContract;
        }
    }

    function setRevoker(address _revoker) public onlyOwner {
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

    function requestUpgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    ) public onlyOwner {
        nextImplementation = _newImplementation;
        nextUpgradeToAndCallDataHash = keccak256(_data);
        etNextUpgradeToAndCall = uint64(block.timestamp) + delay;
        emit UpgradeToAndCallRequest(_newImplementation, _data);
    }

    function upgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    ) public payable override onlyProxy {
        if (_newImplementation != nextImplementation) {
            revert InvalidUpgradeToAndCallImpl();
        }
        if (keccak256(_data) != nextUpgradeToAndCallDataHash) {
            revert InvalidUpgradeToAndCallData();
        }

        uint64 et = etNextUpgradeToAndCall;
        if (et == 0 || et > block.timestamp) {
            revert TooEarlyToUpgradeToAndCall();
        }

        // _authorizeUpgrade(newImplementation);
        // _upgradeToAndCallUUPS(newImplementation, data);
        super.upgradeToAndCall(_newImplementation, _data);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

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

    function revokeNextMessager() public onlyRevoker {
        etNextMessager = 0;
    }

    function revokeNextRevoker() public onlyRevoker {
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
        mintBudget = uint112(mintBudget - amount);
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
        mintBudget += uint112(amount);
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
        address[] memory _recipients,
        uint256[] memory _values
    ) public onlyNotBlocked {
        if (_recipients.length != _values.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            transfer(_recipients[i], _values[i]);
        }
    }

    //-------------
    // get cross-chain message to estimate cross-chain fees
    function msgOfCcSendToken(
        address sender,
        address receiver,
        uint256 value
    ) public view returns (bytes memory message) {
        _checkBlocked(sender);
        _checkBlocked(receiver);
        return abi.encode(TagSendToken, abi.encode(sender, receiver, value));
    }

    // called by the messager contract to initialize a cross-chain token transfer
    function ccSendToken(
        address sender,
        address receiver,
        uint256 value
    ) public onlyMessager returns (bytes memory message) {
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
        return abi.encode(TagSendMintBudget, abi.encode(value));
    }

    // called by the messager contract to initialize a cross-chain mint-budget transfer
    function ccSendMintBudget(
        uint112 value
    ) public onlyMessager returns (bytes memory message) {
        _checkOperator(tx.origin);
        _checkZeroValue(value);
        mintBudget -= value;
        emit CCSendMintBudget(value);
        return msgOfCcSendMintBudget(value);
    }

    // finish a cross-chain token transfer
    function ccReceiveToken(bytes memory message) internal {
        (address sender, address receiver, uint value) = abi.decode(
            message,
            (address, address, uint)
        );
        _mint(receiver, value);
        emit CCReceiveToken(sender, receiver, value);
    }

    // finish a cross-chain mint-budget transfer
    function ccReceiveMintBudget(bytes memory message) internal {
        uint112 value = abi.decode(message, (uint112));
        mintBudget += value;
        emit CCReceiveMintBudget(value);
    }

    // called by the messager contract to handle a received cross-chain message
    function ccReceive(bytes calldata message) public onlyMessager {
        (uint tag, bytes memory data) = abi.decode(message, (uint, bytes));
        if (tag == TagSendToken) {
            ccReceiveToken(data);
        } else if (tag == TagSendMintBudget) {
            ccReceiveMintBudget(data);
        } else {
            revert InvalidMsg(tag);
        }
    }
}
