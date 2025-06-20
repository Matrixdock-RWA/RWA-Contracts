// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/ICCClient.sol";

contract FakeMT is ERC20, ICCIPClient {

    uint constant TagSendToken = 2;
    uint constant TagSendMintBudget = 3;

    uint112 public mintBudget;
    address public messager;

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

    error NotMessager(address);
    error MintBudgetNotEnough(uint budget, uint amount);
    error InvalidMsg(uint tag);

    modifier onlyMessager() {
        if (msg.sender != messager) {
            revert NotMessager(msg.sender);
        }
        _;
    }

    constructor() ERC20("FMT", "FMT") {
        _mint(msg.sender, 1000000000000000000000000);
        mintBudget = 1000000000000000000000000;
    }

    function _checkMintBudget(uint amount) private view {
        if (amount > mintBudget) {
            revert MintBudgetNotEnough(mintBudget, amount);
        }
    }

    function setMessager(address _messager) public {
        messager = _messager;
    }

    function msgOfCcSendToken(
        address sender,
        address receiver,
        uint256 value
    ) public pure returns (bytes memory message) {
        return abi.encode(TagSendToken, abi.encode(sender, receiver, value));
    }

    // called by the messager contract to initialize a cross-chain token transfer
    function ccSendToken(
        address sender,
        address receiver,
        uint256 value
    ) public onlyMessager returns (bytes memory message) {
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
}

