// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";

interface ICCIPClient {
    function ccReceive(bytes calldata message) external;

    function msgOfCcSendToken(
        address sender,
        address receiver,
        uint256 value
    ) external view returns (bytes memory message);

    function ccSendToken(
        address sender,
        address receiver,
        uint256 value
    ) external returns (bytes memory message);

    function msgOfCcSendMintBudget(
        uint112 value
    ) external view returns (bytes memory message);

    function ccSendMintBudget(
        uint112 value
    ) external returns (bytes memory message);
}

contract MTokenMessager is CCIPReceiver, OwnerIsCreator {
    ICCIPClient public ccipClient;

    mapping(uint64 => mapping(address => bool)) public allowedPeer;

    event AllowedPeer(uint64 chainSelector, address messager, bool allowed);
    event CCReceive(bytes32 indexed messageID, bytes messageData);
    event CCSendToken(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudget(bytes32 indexed messageID, bytes messageData);

    error NotInAllowListed(uint64 chainSelector, address messager);
    error InsufficientFee(uint256 required, uint256 actual);

    constructor(address _router, address _ccipClient) CCIPReceiver(_router) {
        ccipClient = ICCIPClient(_ccipClient);
    }

    function setAllowedPeer(
        uint64 chainSelector,
        address messager,
        bool allowed
    ) external onlyOwner {
        allowedPeer[chainSelector][messager] = allowed;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        address sender = abi.decode(any2EvmMessage.sender, (address));
        if (!allowedPeer[any2EvmMessage.sourceChainSelector][sender]) {
            revert NotInAllowListed(any2EvmMessage.sourceChainSelector, sender);
        }

        ccipClient.ccReceive(any2EvmMessage.data);
        emit CCReceive(any2EvmMessage.messageId, any2EvmMessage.data);
    }

    function calculateCCSendTokenFeeAndMessage(
        uint64 destinationChainSelector,
        address messageReceiver,
        address sender,
        address recipient,
        uint value,
        bytes calldata extraArgs
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        bytes memory data = ccipClient.msgOfCcSendToken(
            sender,
            recipient,
            value
        );
        return
            getFeeAndMessage(
                destinationChainSelector,
                messageReceiver,
                extraArgs,
                data
            );
    }

    function calculateCcSendMintBudgetFeeAndMessage(
        uint64 destinationChainSelector,
        address messageReceiver,
        uint112 value,
        bytes calldata extraArgs
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        bytes memory data = ccipClient.msgOfCcSendMintBudget(value);
        return
            getFeeAndMessage(
                destinationChainSelector,
                messageReceiver,
                extraArgs,
                data
            );
    }

    function sendTokenToChain(
        uint64 destinationChainSelector,
        address messageReceiver,
        address recipient,
        uint value,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId) {
        if (!allowedPeer[destinationChainSelector][messageReceiver]) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        bytes memory data = ccipClient.ccSendToken(
            msg.sender,
            recipient,
            value
        );
        return
            sendDataToChain(
                destinationChainSelector,
                messageReceiver,
                extraArgs,
                data
            );
    }

    function sendMintBudgetToChain(
        uint64 destinationChainSelector,
        address messageReceiver,
        uint112 value,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId) {
        if (!allowedPeer[destinationChainSelector][messageReceiver]) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        bytes memory data = ccipClient.ccSendMintBudget(value);
        return
            sendDataToChain(
                destinationChainSelector,
                messageReceiver,
                extraArgs,
                data
            );
    }

    function getFeeAndMessage(
        uint64 destinationChainSelector,
        address messageReceiver,
        bytes calldata extraArgs,
        bytes memory data
    )
        public
        view
        returns (uint256 fee, Client.EVM2AnyMessage memory evm2AnyMessage)
    {
        evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(messageReceiver),
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
        address messageReceiver,
        bytes calldata extraArgs,
        bytes memory data
    ) internal returns (bytes32 messageId) {
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(messageReceiver),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: address(0)
        });
        uint256 fee = IRouterClient(getRouter()).getFee(
            destinationChainSelector,
            evm2AnyMessage
        );
        if (msg.value < fee) {
            revert InsufficientFee(fee, msg.value);
        }
        messageId = IRouterClient(getRouter()).ccipSend{value: fee}(
            destinationChainSelector,
            evm2AnyMessage
        );
        if (msg.value - fee > 0) {
            bool success = payable(msg.sender).send(msg.value - fee);
            require(success, "MTokenMessager: TRANSFER_FAILED");
        }
        emit CCSendToken(messageId, data);
        return messageId;
    }
}
