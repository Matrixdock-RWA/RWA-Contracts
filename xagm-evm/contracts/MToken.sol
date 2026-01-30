// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "./DelayedUpgradeable.sol";
import "./interfaces/ICCClient.sol";
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

    // the messager contract takes care of cross-chain task
    address public messager;
    address public nextMessager;
    uint64 public etNextMessager; //effective time

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
    address public fallbackFeed;
    address public nextFallbackFeed;
    uint64 public etNextFallbackFeed; //effective time

    // fee-on-transfer (basis points, 10000 = 100%)
    address public feeRecipient;
    address public nextFeeRecipient;
    uint64 public etNextFeeRecipient; //effective time

    uint16 public feeBP; // e.g. 30 = 0.3%
    uint16 public nextFeeBP;
    uint64 public etNextFeeBP; //effective time

    uint maxFee; // in local decimals
    uint nextMaxFee;
    uint64 etNextMaxFee; //effective time
}

// this contract will be deployed on EVM-compatible chains other than Ethereum
contract MToken is MTokenBase, ICCIPClient {
    uint64 constant MIN_DELAY = 1 hours;

    uint constant TagSendToken = 2;
    uint constant TagSendMintBudget = 3;

    uint16 constant MAX_FEE_BP_CAP = 1000; // 10%
    uint256 constant MAX_FEE_CAP = 50000 * 10 ** 18; // 50k
    uint256 constant FEE_BASE = 10000;

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
    event SetFeeBPRequest(uint16 oldBP, uint16 newBP, uint64 et);
    event SetFeeBPEffected(uint16 newBP);
    event SetMaxFeeRequest(uint256 oldMaxFee, uint256 newMaxFee, uint64 et);
    event SetMaxFeeEffected(uint256 newMaxFee);
    event SetFeeRecipientRequest(address oldAddr, address newAddr, uint64 et);
    event SetFeeRecipientEffected(address newAddr);
    event ControllerTransfer(
        address _controller,
        address indexed _from,
        address indexed _to,
        uint256 _value,
        bytes _data,
        bytes _operatorData
    );

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
    error DelayTooSmall();
    error FeeBPTooLarge(uint16 bp);
    error MaxFeeTooLarge(uint256 maxFee);

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
        _checkZeroAddress(_messager);
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

    function setFeeBP(uint16 _feeBP) public onlyOwner {
        if (_feeBP > MAX_FEE_BP_CAP) {
            revert FeeBPTooLarge(_feeBP);
        }
        uint64 et = etNextFeeBP;
        if (_feeBP == nextFeeBP && et != 0 && et < block.timestamp) {
            feeBP = _feeBP;
            emit SetFeeBPEffected(_feeBP);
        } else {
            nextFeeBP = _feeBP;
            etNextFeeBP = uint64(block.timestamp) + delay;
            emit SetFeeBPRequest(feeBP, _feeBP, etNextFeeBP);
        }
    }

    function setMaxFee(uint _maxFee) public onlyOwner {
        if (_maxFee > MAX_FEE_CAP) {
            revert MaxFeeTooLarge(_maxFee);
        }
        uint64 et = etNextMaxFee;
        if (_maxFee == nextMaxFee && et != 0 && et < block.timestamp) {
            maxFee = _maxFee;
            emit SetMaxFeeEffected(_maxFee);
        } else {
            nextMaxFee = _maxFee;
            etNextMaxFee = uint64(block.timestamp) + delay;
            emit SetMaxFeeRequest(maxFee, _maxFee, etNextMaxFee);
        }
    }

    function setFeeRecipient(address _recipient) public onlyOwner {
        _checkZeroAddress(_recipient);
        uint64 et = etNextFeeRecipient;
        if (_recipient == nextFeeRecipient && et != 0 && et < block.timestamp) {
            feeRecipient = _recipient;
            emit SetFeeRecipientEffected(_recipient);
        } else {
            nextFeeRecipient = _recipient;
            etNextFeeRecipient = uint64(block.timestamp) + delay;
            emit SetFeeRecipientRequest(feeRecipient, _recipient, etNextFeeRecipient);
        }
    }

    // controller transfer not fee deducted
    function controllerTransfer(address _from, address _to, uint256 _value, bytes calldata _data, bytes calldata _operatorData) external onlyOwner {
        _transfer(_from, _to, _value);
        emit ControllerTransfer(msg.sender, _from, _to, _value, _data, _operatorData);
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

    function revokeNextMessager() public onlyRevoker {
        etNextMessager = 0;
    }

    function revokeNextRevoker() public onlyRevoker {
        etNextRevoker = 0;
    }

    function revokeNextFeeRecipient() public onlyRevoker {
        etNextFeeRecipient = 0;
    }

    function revokeNextFeeBP() public onlyRevoker {
        etNextFeeBP = 0;
    }

    function revokeNextMaxFee() public onlyRevoker {
        etNextMaxFee = 0;
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
        uint fee = calcFee(_amount);
        if (fee > 0) {
            super.transfer(feeRecipient, fee);
            _amount -= fee;
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
        uint fee = calcFee(_amount);
        if (fee > 0) {
            super.transferFrom(_sender, feeRecipient, fee);
            _amount -= fee;
        }
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
        uint fee = calcFee(value);
        if (fee > 0) {
            _transfer(sender, feeRecipient, fee);
            value -= fee;
        }
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
        message = msgOfCcSendMintBudget(value);
        mintBudget -= value;
        emit CCSendMintBudget(value);
        return message;
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

    function calcFee(uint _value) public view returns (uint) {
        uint fee = _value * feeBP / FEE_BASE;
        if (fee > maxFee) {
            fee = maxFee;
        }
        return fee;
    }
}
