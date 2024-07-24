// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";

contract FakeRouterClient {
    bytes32 public lastMsgId;
    mapping(bytes32 msgId => Client.EVM2AnyMessage) public msgMap;
    mapping(bytes32 msgId => address) public senderMap;

    function getFee(
        uint64 /*destinationChainSelector*/,
        Client.EVM2AnyMessage memory message
    ) external pure returns (uint256 fee) {
        return message.data.length * 10000;
    }

    function ccipSend(
        uint64 /*destinationChainSelector*/,
        Client.EVM2AnyMessage calldata message
    ) external payable returns (bytes32) {
        lastMsgId = keccak256(message.data);
        msgMap[lastMsgId] = message;
        senderMap[lastMsgId] = msg.sender;
        return lastMsgId;
    }

    function callCcipReceive(
        address addr,
        Client.Any2EVMMessage calldata _msg
    ) public {
        CCIPReceiver(addr).ccipReceive(_msg);
    }

    function callCcipReceiveByMsgId(bytes32 msgId) public {
        Client.EVM2AnyMessage memory msg1 = msgMap[msgId];
        address receiver = abi.decode(msg1.receiver, (address));
        address sender = senderMap[msgId];

        Client.Any2EVMMessage memory msg2 = Client.Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: 100, // hardcoded for test
            sender: abi.encode(sender),
            data: msg1.data,
            destTokenAmounts: msg1.tokenAmounts
        });

        CCIPReceiver(receiver).ccipReceive(msg2);
    }
}
