// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {BullionMinter} from "./BullionMinter.sol";

// BullionMinter adapted for Tron, where USDT does not return a boolean from transfer().
contract BullionMinterForTron is BullionMinter {
    // nile:0xECa9bC828A3005B9a3b909f2cc5c2a54794DE05F  mainnet:0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C
    address public usdtAddr;

    function initialize(
        address _owner,
        address _usdt,
        address _poolAccountA,
        address _poolAccountB,
        address[] calldata _tokensAcceptedByA,
        address[] calldata _tokensAcceptedByB
    ) public initializer {
        __Minter_init(_owner, _poolAccountA, _poolAccountB, _tokensAcceptedByA, _tokensAcceptedByB);
        usdtAddr = _usdt;
    }

    // Override rescue to handle Tron USDT which does not return a boolean from transfer().
    function rescue(address token, address receiver, uint amount) onlyOwner external override {
        _tronSafeTransfer(token, receiver, amount);
        emit Rescue(token, receiver, amount);
    }

    function _tronSafeTransfer(address token, address to, uint value) internal returns (bool) {
        // bytes4(keccak256(bytes('transfer(address,uint256)')))
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (token == usdtAddr) {
            return success;
        }
        return (success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
