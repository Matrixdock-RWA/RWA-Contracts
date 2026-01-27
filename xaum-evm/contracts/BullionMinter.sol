// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DelayedUpgradeable} from "./DelayedUpgradeable.sol";

contract BullionMinter is DelayedUpgradeable {
    using SafeERC20 for IERC20;

    address public poolAccountA; //stable coin pool
    address public poolAccountB; //rwa pool
    mapping(address token => bool accepted) public acceptedByA;
    mapping(address token => bool accepted) public acceptedByB;

    uint public constant DELAY_MAX = 59;

    // note: not currently used but retained for historical reasons
    // to make it easier to view these two values
    uint8 public constant PREPRICE_DECIMAL = 6;
    uint8 public constant SLIPPAGE_DECIMAL = 6;

    function __Minter_init(
        address _owner,
        address _poolAccountA,
        address _poolAccountB,
        address[] calldata _tokensAcceptedByA,
        address[] calldata _tokensAcceptedByB
    ) internal onlyInitializing {
        __Ownable_init_unchained(_owner);
        poolAccountA = _poolAccountA;
        poolAccountB = _poolAccountB;
        for (uint i; i < _tokensAcceptedByA.length; i++) {
            acceptedByA[_tokensAcceptedByA[i]] = true;
        }
        for (uint i; i < _tokensAcceptedByB.length; i++) {
            acceptedByB[_tokensAcceptedByB[i]] = true;
        }
    }

    function initialize(
        address _owner,
        address _poolAccountA,
        address _poolAccountB,
        address[] calldata _tokensAcceptedByA,
        address[] calldata _tokensAcceptedByB
    ) public initializer {
        __Minter_init(_owner, _poolAccountA, _poolAccountB, _tokensAcceptedByA, _tokensAcceptedByB);
    }

    event SetPoolAccountA(address poolAccountA);
    event SetPoolAccountB(address poolAccountB);
    event SetAcceptedByA(address token, bool accepted);
    event SetAcceptedByB(address token, bool accepted);
    event MintRequest(address indexed transferredToken, address indexed forToken,
               address indexed requestor, address pool, uint amount, uint preprice, uint slippage, bytes extraData);
    event RedeemRequest(address indexed transferredToken, address indexed forToken,
               address indexed requestor, address pool, uint amount, uint preprice, uint slippage, bytes extraData);

    function getDelay() internal pure override returns (uint64) {
        return 3600 * 12; //upgrade must be delayed by 12 hours
    }

    function setPoolAccountA(address _poolAccountA) onlyOwner() external {
        _checkZeroAddress(_poolAccountA);
        poolAccountA = _poolAccountA;
        emit SetPoolAccountA(_poolAccountA);
    }

    function setPoolAccountB(address _poolAccountB) onlyOwner() external {
        _checkZeroAddress(_poolAccountB);
        poolAccountB = _poolAccountB;
        emit SetPoolAccountB(_poolAccountB);
    }

    function setAcceptedByA(address token, bool accepted) onlyOwner() external {
        _checkZeroAddress(token);
        acceptedByA[token] = accepted;
        emit SetAcceptedByA(token, accepted);
    }

    function setAcceptedByB(address token, bool accepted) onlyOwner() external {
        _checkZeroAddress(token);
        acceptedByB[token] = accepted;
        emit SetAcceptedByB(token, accepted);
    }

    // Most parameters are not checked here and are handled by the off-chain service.
    // note: owner is trusted not to front-run by changing poolAccountA; owner is securely
    // held in the wallet's escrow system; every owner transaction undergoes a two-step
    // process of signature and verification
    function requestToMint(address transferredToken, address forToken, uint amount, uint preprice, uint slippage, uint timestamp, bytes calldata extraData) external {
        require(acceptedByA[transferredToken], "INVALID_TOKEN_FOR_MINTING");
        require(block.timestamp <= timestamp + DELAY_MAX, "INVALID_TIMESTAMP");
        address _poolAccountA = poolAccountA;
        IERC20(transferredToken).safeTransferFrom(msg.sender, _poolAccountA, amount);
        emit MintRequest(transferredToken, forToken, msg.sender, _poolAccountA, amount, preprice, slippage, extraData);
    }

    // Most parameters are not checked here and are handled by the off-chain service.
    // note: owner is trusted not to front-run by changing poolAccountB; owner is securely
    // held in the wallet's escrow system; every owner transaction undergoes a two-step
    // process of signature and verification
    function requestToRedeem(address transferredToken, address forToken, uint amount, uint preprice, uint slippage, uint timestamp, bytes calldata extraData) external {
        require(acceptedByB[transferredToken], "INVALID_TOKEN_FOR_REDEEMING");
        require(block.timestamp <= timestamp + DELAY_MAX, "INVALID_TIMESTAMP");
        address _poolAccountB = poolAccountB;
        IERC20(transferredToken).safeTransferFrom(msg.sender, _poolAccountB, amount);
        emit RedeemRequest(transferredToken, forToken, msg.sender, _poolAccountB, amount, preprice, slippage, extraData);
    }

    // rescue ERC20 tokens which were accidentally sent to this contract
    function rescue(address token, address receiver, uint amount) onlyOwner external {
        IERC20(token).safeTransfer(receiver, amount);
    }
}

