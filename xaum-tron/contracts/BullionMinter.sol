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
    uint constant public delayMax = 59;
    // nile:0xECa9bC828A3005B9a3b909f2cc5c2a54794DE05F  mainnet:0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C
    address public usdtAddr;

    function __Minter_init(
        address _owner,
        address _usdt,
        address _poolAccountA,
        address _poolAccountB,
        address[] memory _tokensAcceptedByA,
        address[] memory _tokensAcceptedByB
    ) internal onlyInitializing {
        __Ownable_init_unchained(_owner);
        usdtAddr = _usdt;
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
        address _usdt,
        address _poolAccountA,
        address _poolAccountB,
        address[] memory _tokensAcceptedByA,
        address[] memory _tokensAcceptedByB
    ) public initializer {
        __Minter_init(_owner, _usdt, _poolAccountA, _poolAccountB, _tokensAcceptedByA, _tokensAcceptedByB);
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

    function requestToMint(address transferredToken, address forToken, uint amount, uint preprice, uint slippage, uint timestamp) external {
        require(acceptedByA[transferredToken], "INVALID_TOKEN_FOR_MINTING");
        require(block.timestamp <= timestamp + delayMax, "INVALID_TIMESTAMP");
        IERC20(transferredToken).safeTransferFrom(msg.sender, poolAccountA, amount);
        emit MintRequest(transferredToken, forToken, msg.sender, poolAccountA, amount, preprice, slippage);
    }

    function requestToRedeem(address transferredToken, address forToken, uint amount, uint preprice, uint slippage, uint timestamp) external {
        require(acceptedByB[transferredToken], "INVALID_TOKEN_FOR_REDEEMING");
        require(block.timestamp <= timestamp + delayMax, "INVALID_TIMESTAMP");
        IERC20(transferredToken).safeTransferFrom(msg.sender, poolAccountB, amount);
        emit RedeemRequest(transferredToken, forToken, msg.sender, poolAccountB, amount, preprice, slippage);
    }

    // rescue ERC20 tokens which were accidentally sent to this contract
    function rescue(address token, address receiver, uint amount) onlyOwner external {
        _safeTransfer(token, receiver, amount);
    }

    function _safeTransfer(address token, address to, uint value) internal returns (bool){
        // bytes4(keccak256(bytes(‘transfer(address,uint256)‘)));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (token == usdtAddr) {
            return success;
        }
        return (success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

