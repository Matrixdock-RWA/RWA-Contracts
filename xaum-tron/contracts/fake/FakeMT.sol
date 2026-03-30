// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/ICCClient.sol";

contract FakeMT is ERC20, ICCClient {

    uint112 public mintBudget;
    address public messenger;

    constructor() ERC20("FMT", "FMT") {
        _mint(msg.sender, 1000000000000000000000000);
        mintBudget = 1000000000000000000000000;
    }

    uint64 constant MIN_DELAY = 1 hours;
    uint64 constant MAX_DELAY = 48 hours;

    uint constant TagSendToken = 2;
    uint constant TagSendMintBudget = 3;

    uint8 constant LOCAL_DECIMALS = 18;
    uint8 constant SHARED_DECIMALS = 9;
    uint256 constant DECIMALS_SCALE_FACTOR =
    10 ** (LOCAL_DECIMALS - SHARED_DECIMALS);

    event CCSendToken(address indexed sender, bytes receiver, uint value);
    event CCSendMintBudget(uint112 value);
    event CCReceiveToken(bytes sender, address indexed receiver, uint value);
    event CCReceiveMintBudget(uint112 value);

    error NotMessenger(address);
    error MintBudgetNotEnough(uint budget, uint amount);
    error CcSendDisabled();
    error InvalidMsg(uint tag);
    error InvalidReceiver(uint length);
    error PrecisionLost();

    modifier onlyMessenger() {
        if (msg.sender != messenger) {
            revert NotMessenger(msg.sender);
        }
        _;
    }

    function _checkMintBudget(uint amount) private view {
        if (amount > mintBudget) {
            revert MintBudgetNotEnough(mintBudget, amount);
        }
    }

    function setMessenger(address _messenger) public {
        messenger = _messenger;
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
        value = convertToSharedDecimals(value);
        bytes memory senderBytes = abi.encodePacked(sender);
        bytes memory body = abi.encode(senderBytes, receiverBytes, value);
        return abi.encode(TagSendToken, body);
    }

    // called by the messenger contract to initialize a cross-chain token transfer
    function ccSendToken(
        address sender,
        bytes calldata receiver,
        uint256 value
    ) public onlyMessenger returns (bytes memory message) {
        _burn(sender, value);
        emit CCSendToken(sender, receiver, value);
        return msgOfCcSendToken(sender, receiver, value);
    }

    function msgOfCcSendMintBudget(
        uint112 value
    ) public view returns (bytes memory message) {
        _checkMintBudget(value);
        value = uint112(convertToSharedDecimals(value));
        return abi.encode(TagSendMintBudget, abi.encode(value));
    }

    // called by the messenger contract to initialize a cross-chain mint-budget transfer
    function ccSendMintBudget(
        uint112 value
    ) public onlyMessenger returns (bytes memory message) {
        message = msgOfCcSendMintBudget(value);
        mintBudget -= value;
        emit CCSendMintBudget(value);
        return message;
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
        value = uint112(convertToLocalDecimals(value));
        mintBudget += value;
        emit CCReceiveMintBudget(value);
    }

    // called by the messenger contract to handle a received cross-chain message
    function ccReceive(bytes calldata message) public onlyMessenger {
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

