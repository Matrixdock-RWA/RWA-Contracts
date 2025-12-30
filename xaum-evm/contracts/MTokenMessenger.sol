// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MTokenMessengerLZ} from "./MTokenMessengerLZ.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";

/*

   CCIP                                |   LayerZero
---------------------------------------+--------------------------------
setAllowedPeer                         | lzSetPeer
sendTokenToChain                       | lzSendTokenToChain
sendMintBudgetToChain                  | lzSendMintBudgetToChain
calculateCCSendTokenFeeAndMessage      | lzCalculateSendTokenFee
calculateCcSendMintBudgetFeeAndMessage | lzCalculateSendMintBudgetFee

*/

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract MTokenMessenger is CCIPReceiver, MTokenMessengerLZ {
    using Address for address payable;

    mapping(uint64 chainSelector => mapping(bytes messenger => bool allowed))
        public allowedPeer;

    event AllowedPeer(uint64 chainSelector, bytes messenger, bool allowed);
    event CCReceive(bytes32 indexed messageID, bytes messageData);
    event CCSendToken(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudget(bytes32 indexed messageID, bytes messageData);

    error NotInAllowListed(uint64 chainSelector, bytes messenger);
    error InsufficientFee(uint256 required, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _ccipRouter,
        address _lzEndpoint
    ) CCIPReceiver(_ccipRouter) MTokenMessengerLZ(_lzEndpoint) {}

    // CCIP related config.
    function setAllowedPeer(
        uint64 chainSelector,
        bytes calldata messenger,
        bool allowed
    ) external onlyOwner {
        allowedPeer[chainSelector][messenger] = allowed;
        emit AllowedPeer(chainSelector, messenger, allowed);
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        uint64 chainSelector = any2EvmMessage.sourceChainSelector;
        bytes memory sender = any2EvmMessage.sender;
        if (!allowedPeer[chainSelector][sender]) {
            revert NotInAllowListed(chainSelector, sender);
        }

        ICCClient(ccClient).ccReceive(any2EvmMessage.data);
        emit CCReceive(any2EvmMessage.messageId, any2EvmMessage.data);
    }

    function calculateCCSendTokenFeeAndMessage(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        address sender,
        bytes calldata recipient,
        uint value,
        bytes calldata extraArgs
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        bytes memory data = ICCClient(ccClient).msgOfCcSendToken(
            sender,
            recipient,
            value
        );
        (fee, evm2AnyMessage) = getFeeAndMessage(
            destinationChainSelector,
            messageReceiver,
            extraArgs,
            data
        );
    }

    function calculateCcSendMintBudgetFeeAndMessage(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        uint112 value,
        bytes calldata extraArgs
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        bytes memory data = ICCClient(ccClient).msgOfCcSendMintBudget(value);
        (fee, evm2AnyMessage) = getFeeAndMessage(
            destinationChainSelector,
            messageReceiver,
            extraArgs,
            data
        );
    }

    function sendTokenToChain(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        bytes calldata recipient,
        uint value,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId) {
        if (!allowedPeer[destinationChainSelector][messageReceiver]) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        bytes memory data = ICCClient(ccClient).ccSendToken(
            msg.sender,
            recipient,
            value
        );
        messageId = sendDataToChain(
            destinationChainSelector,
            messageReceiver,
            extraArgs,
            data
        );
        emit CCSendToken(messageId, data);
    }

    function sendMintBudgetToChain(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        uint112 value,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId) {
        if (!allowedPeer[destinationChainSelector][messageReceiver]) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        bytes memory data = ICCClient(ccClient).ccSendMintBudget(value);
        messageId = sendDataToChain(
            destinationChainSelector,
            messageReceiver,
            extraArgs,
            data
        );
        emit CCSendMintBudget(messageId, data);
    }

    function getFeeAndMessage(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        bytes calldata extraArgs,
        bytes memory data
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: messageReceiver,
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: address(0)
        });
        fee = IRouterClient(getRouter()).getFee(
            destinationChainSelector,
            evm2AnyMessage
        );
    }

    function sendDataToChain(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        bytes calldata extraArgs,
        bytes memory data
    ) internal returns (bytes32 messageId) {
        (
            uint256 fee,
            Client.EVM2AnyMessage memory evm2AnyMessage
        ) = getFeeAndMessage(
                destinationChainSelector,
                messageReceiver,
                extraArgs,
                data
            );
        if (msg.value < fee) {
            revert InsufficientFee(fee, msg.value);
        }
        messageId = IRouterClient(getRouter()).ccipSend{value: fee}(
            destinationChainSelector,
            evm2AnyMessage
        );
        if (msg.value - fee > 0) {
            payable(msg.sender).sendValue(msg.value - fee);
        }
        return messageId;
    }
}
