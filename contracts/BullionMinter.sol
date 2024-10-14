// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./DelayedUpgradeable.sol";

contract BullionMinter is DelayedUpgradeable {
    using SafeERC20 for IERC20;

    address public poolAccountA;
    address public poolAccountB;
    mapping(address token => bool accepted) public acceptedByA;
    mapping(address token => bool accepted) public acceptedByB;
    uint8 constant public prepriceDecimal = 6;
    uint8 constant public slippageDecimal = 6;

    function __Minter_init(
        address _owner,
        address _poolAccountA,
        address _poolAccountB,
        address[] memory _tokensAcceptedByA,
        address[] memory _tokensAcceptedByB
    ) internal onlyInitializing {
        __Ownable_init_unchained(_owner);
        poolAccountA = _poolAccountA;
        poolAccountB = _poolAccountB;
        for(uint i=0; i<_tokensAcceptedByA.length; i++) {
            acceptedByA[_tokensAcceptedByA[i]] = true;
        }
        for(uint i=0; i<_tokensAcceptedByB.length; i++) {
            acceptedByB[_tokensAcceptedByB[i]] = true;
        }
    }

    function initialize(
        address _owner,
        address _poolAccountA,
        address _poolAccountB,
        address[] memory _tokensAcceptedByA,
        address[] memory _tokensAcceptedByB
    ) public initializer {
        __Minter_init(_owner, _poolAccountA, _poolAccountB, _tokensAcceptedByA, _tokensAcceptedByB);
    }

    event SetPoolAccountA(address poolAccountA);
    event SetPoolAccountB(address poolAccountB);
    event SetAcceptedByA(address token, bool accepted);
    event SetAcceptedByB(address token, bool accepted);
    event MintRequest(address indexed transferredToken, address indexed forToken,
               address indexed requestor, address pool, uint amount, uint preprice, uint slippage);
    event RedeemRequest(address indexed transferredToken, address indexed forToken,
               address indexed requestor, address pool, uint amount, uint preprice, uint slippage);

    function getDelay() internal pure override returns (uint64) {
        return 3600 * 12; //upgrade must be delayed by 12 hours
    }

    function setPoolAccountA(address _poolAccountA) onlyOwner() external {
        poolAccountA = _poolAccountA;
        emit SetPoolAccountA(_poolAccountA);
    }

    function setPoolAccountB(address _poolAccountB) onlyOwner() external {
        poolAccountB = _poolAccountB;
        emit SetPoolAccountB(_poolAccountB);
    }

    function setAcceptedByA(address token, bool accepted) onlyOwner() external {
        acceptedByA[token] = accepted;
        emit SetAcceptedByA(token, accepted);
    }

    function setAcceptedByB(address token, bool accepted) onlyOwner() external {
        acceptedByB[token] = accepted;
        emit SetAcceptedByB(token, accepted);
    }

    function requestToMint(address transferredToken, address forToken, uint amount, uint preprice, uint slippage) external {
        require(acceptedByA[transferredToken], "INVALID_TOKEN_FOR_MINTING");
        IERC20(transferredToken).safeTransferFrom(msg.sender, poolAccountA, amount);
        emit MintRequest(transferredToken, forToken, msg.sender, poolAccountA, amount, preprice, slippage);
    }

    function requestToRedeem(address transferredToken, address forToken, uint amount, uint preprice, uint slippage) external {
        require(acceptedByB[transferredToken], "INVALID_TOKEN_FOR_REDEEMING");
        IERC20(transferredToken).safeTransferFrom(msg.sender, poolAccountB, amount);
        emit RedeemRequest(transferredToken, forToken, msg.sender, poolAccountB, amount, preprice, slippage);
    }

    // rescue ERC20 tokens which were accidentally sent to this contract
    function rescue(address token, address receiver, uint amount) onlyOwner external {
        IERC20(token).safeTransfer(receiver, amount);
    }
}

