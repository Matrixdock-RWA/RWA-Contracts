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
addAllowedPeer / removeAllowedPeer     | lzAddPeer / lzRemovePeer
sendTokenToChain                       | lzSendTokenToChain
sendMintBudgetToChain                  | lzSendMintBudgetToChain
calculateCCSendTokenFeeAndMessage      | lzCalculateSendTokenFee
calculateCcSendMintBudgetFeeAndMessage | lzCalculateSendMintBudgetFee

*/

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract MTokenMessenger is CCIPReceiver, MTokenMessengerLZ {
    using Address for address payable;

    struct PeerInfo {
        bool allowed;
        uint8 addrLen; // 0 means no address length check
    }

    // messenger must be 32 bytes (left padded with 0) if chainSelector points to an EVM chain
    mapping(uint64 chainSelector => mapping(bytes messenger => PeerInfo))
        public allowedPeer;

    bytes32 constant OP_ADD_ALLOWED_PEER = keccak256("OP_ADD_ALLOWED_PEER");

    event AddAllowedPeerEffected(uint64 chainSelector, bytes messenger, uint8 addrLen);
    event AllowedPeerRemoved(uint64 chainSelector, bytes messenger);
    event AddAllowedPeerRequest(uint64 chainSelector, bytes messenger, uint8 addrLen, uint64 et);
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

    // CCIP related config: allow a peer. Granting a peer is risk-expanding
    // (it can send messages that mint on this chain), so it goes through the
    // normal `delay` before taking effect (two-call pattern, same as mintTo).
    function addAllowedPeer(
        uint64 chainSelector,
        bytes calldata messenger,
        uint8 addrLen
    ) external onlyOwner {
        uint64 et = ensureDelay(_addAllowedPeerReqHash(chainSelector, messenger), addrLen, delay);
        if (et == 0) {
            allowedPeer[chainSelector][messenger] = PeerInfo({
                allowed: true,
                addrLen: addrLen
            });
            emit AddAllowedPeerEffected(chainSelector, messenger, addrLen);
        } else {
            emit AddAllowedPeerRequest(chainSelector, messenger, addrLen, et);
        }
    }

    function revokeAddAllowedPeer(uint64 chainSelector, bytes calldata messenger) external onlyOwner {
        revoke(_addAllowedPeerReqHash(chainSelector, messenger));
    }

    // CCIP related config: remove a peer. This is a safety action and takes
    // effect immediately, unlike addAllowedPeer.
    function removeAllowedPeer(
        uint64 chainSelector,
        bytes calldata messenger
    ) external onlyOwner {
        // clear any pending add request so it cannot mature right after removal
        // and silently re-allow the peer, bypassing the intent of this safety action
        revoke(_addAllowedPeerReqHash(chainSelector, messenger));
        delete allowedPeer[chainSelector][messenger];
        emit AllowedPeerRemoved(chainSelector, messenger);
    }

    function _addAllowedPeerReqHash(
        uint64 chainSelector,
        bytes calldata messenger
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(OP_ADD_ALLOWED_PEER, chainSelector, messenger));
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        uint64 chainSelector = any2EvmMessage.sourceChainSelector;
        bytes memory sender = any2EvmMessage.sender;
        if (!allowedPeer[chainSelector][sender].allowed) {
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
        uint256 value,
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

    // note: unlike LayerZero component, there is no way to specifically pause CCIP
    // send transactions. To pause CCIP requires enabling disableCcSend which will
    // pause both CCIP & LayerZero send txns. We are gradually deprecating CCIP
    function sendTokenToChain(
        uint64 destinationChainSelector,
        bytes calldata messageReceiver,
        bytes calldata recipient,
        uint256 value,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId) {
        PeerInfo memory peer = allowedPeer[destinationChainSelector][messageReceiver];
        if (!peer.allowed) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        if (peer.addrLen != 0 && recipient.length != peer.addrLen) {
            revert InvalidRecipientLength(peer.addrLen, uint8(recipient.length));
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
        if (!allowedPeer[destinationChainSelector][messageReceiver].allowed) {
            revert NotInAllowListed(destinationChainSelector, messageReceiver);
        }
        bytes memory data = ICCClient(ccClient).ccSendMintBudget(value, msg.sender);
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
    }
}
