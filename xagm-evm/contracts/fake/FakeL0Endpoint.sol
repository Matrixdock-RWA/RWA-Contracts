// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { 
    ILayerZeroEndpointV2, 
    MessagingParams, 
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IOAppReceiver, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import "hardhat/console.sol";

/*
struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}
*/

contract FakeL0Endpoint {

    address public delegate;

    bytes32 public lastMsgId;
    mapping(bytes32 msgId => MessagingParams) public msgMap;
    mapping(bytes32 msgId => address) public senderMap;


    function setDelegate(address _delegate) external {
        // console.log('FakeL0Endpoint: setDelegate(%s)', _delegate);
        delegate = _delegate;
    }

    function callLzReceive(
        address addr, 
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) public {
        // console.log('FakeL0Endpoint: callLzReceive(%s, ...)', addr);
        IOAppReceiver(addr).lzReceive(
            _origin, _guid, _message, _executor, _extraData);
    }

    function quote(
        MessagingParams calldata _params, 
        address /*_sender*/
    ) external pure returns (MessagingFee memory) {
        // console.log('FakeL0Endpoint: quote(..., %s)', _sender);
        return MessagingFee(_params.message.length * 10000, 0);
    }

    function send(
        MessagingParams calldata _params,
        address /*_refundAddress*/
    ) external payable returns (MessagingReceipt memory) {
        // console.log('FakeL0Endpoint: send(..., %s)', _refundAddress);
        lastMsgId = keccak256(_params.message);
        uint64 nonce = uint64(uint256(lastMsgId));
        msgMap[lastMsgId] = _params;
        senderMap[lastMsgId] = msg.sender;
        return MessagingReceipt(lastMsgId, nonce, MessagingFee(0, 0));
    }

    function callLzReceiveByMsgId(bytes32 msgId) public {
        MessagingParams memory msg1 = msgMap[msgId];
        address receiver = address(uint160(uint256(msg1.receiver)));
        address sender = senderMap[msgId];
        // console.log('FakeL0Endpoint: callLzReceiveByMsgId, receiver: %s, sender: %s', receiver, sender);

        uint32 srcEid = 100; // hardcoded for test
        bytes32 sender32 = bytes32(uint256(uint160(sender)));
        uint64 nonce = uint64(uint256(msgId));
        Origin memory origin = Origin(srcEid, sender32, nonce);

        IOAppReceiver(receiver).lzReceive(
            origin, msgId, msg1.message, address(this), msg1.options);
    }

}
