// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MTokenMessagerBase} from "../MTokenMessagerBase.sol";
import {ICCClientV2} from "../interfaces/ICCClientV2.sol";

// 32bytes address version
contract MTokenMessagerLZV2 is MTokenMessagerBase, OApp {
    bool public lzPaused;

    event CCReceiveLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendTokenLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudgetLZ(bytes32 indexed messageID, bytes messageData);
    event LZPaused(bool isPaused);

    modifier onlyLZNotPaused() {
        require(!lzPaused, "LZ_PAUSED");
        _;
    }

    constructor(
        address _ccipClient,
        address _endpoint,
        address _initialOwner
    )
        MTokenMessagerBase(_ccipClient)
        OApp(_endpoint, _initialOwner)
        Ownable(_initialOwner)
    {}

    function setLZPaused(bool isPaused) public onlyOwner {
        lzPaused = isPaused;
        emit LZPaused(isPaused);
    }

    // to differentiate from setAllowedPeer in MTokenMessager
    function lzSetPeer(uint32 _eid, bytes32 _peer) public onlyOwner {
        setPeer(_eid, _peer);
    }

    // lz OApp receive implementation
    function _lzReceive(
        Origin calldata, // _origin
        bytes32 _guid,
        bytes calldata payload,
        address, // Executor address as specified by the OApp.
        bytes calldata // Any extra data or options to trigger on receipt.
    ) internal override {
        // src sender check already made in OApp.
        ICCClientV2(ccClient).ccReceive32(payload);
        emit CCReceiveLZ(_guid, payload);
    }

    function lzSendTokenToChain(
        uint32 _dstEid,
        bytes32 recipient,
        uint value,
        bytes calldata _options
    ) external payable onlyLZNotPaused returns (bytes32 messageId) {
        bytes memory _data = ICCClientV2(ccClient).ccSendToken32(
            msg.sender,
            recipient,
            value
        );
        messageId = sendThroughLZ(_dstEid, _data, _options, msg.value);
        emit CCSendTokenLZ(messageId, _data);
    }

    function lzSendMintBudgetToChain(
        uint32 _dstEid,
        uint112 value,
        bytes calldata _options
    ) external payable onlyLZNotPaused returns (bytes32 messageId) {
        bytes memory _data = ICCClientV2(ccClient).ccSendMintBudget32(value);
        messageId = sendThroughLZ(_dstEid, _data, _options, msg.value);
        emit CCSendMintBudgetLZ(messageId, _data);
    }

    // lz OApp send implementation
    function sendThroughLZ(
        uint32 _dstEid,
        bytes memory _payload,
        bytes calldata _options,
        uint256 msgValue
    ) internal returns (bytes32 guid) {
        MessagingFee memory fee = _quote(_dstEid, _payload, _options, false);
        require(msgValue >= fee.nativeFee, "LZ_INSUFFICIENT_FEE");
        MessagingReceipt memory receipt = _lzSend(
            _dstEid,
            _payload,
            _options,
            MessagingFee(msgValue, 0), // Fee in native gas and ZRO token.
            payable(msg.sender) // Refund address in case of failed source message.
        );
        return receipt.guid;
    }

    // --------------- query functions -----------------

    function lzCalculateSendTokenFee(
        uint32 _dstEid, // Destination chain's endpoint ID.
        address sender,
        bytes32 recipient,
        uint value,
        bytes calldata _options // Message execution options
    ) public view returns (uint256 nativeFee) {
        bytes memory _data = ICCClientV2(ccClient).msgOfCcSendToken32(
            sender,
            recipient,
            value
        );
        MessagingFee memory fee = _quote(_dstEid, _data, _options, false);
        return fee.nativeFee;
    }

    function lzCalculateSendMintBudgetFee(
        uint32 _dstEid, // Destination chain's endpoint ID.
        uint112 value,
        bytes calldata _options
    ) public view returns (uint256 nativeFee) {
        bytes memory _data = ICCClientV2(ccClient).msgOfCcSendMintBudget(value);
        MessagingFee memory fee = _quote(_dstEid, _data, _options, false);
        return fee.nativeFee;
    }
}
