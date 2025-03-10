// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import "./MTokenMessagerBase.sol";
import "./interfaces/ICCIPClient.sol";

contract MTokenMessagerLZ is MTokenMessagerBase, OApp {

    bool public lzPaused;

    event CCReceiveLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendTokenLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudgetLZ(bytes32 indexed messageID, bytes messageData);
    event OwnershipTransferRequested(address indexed from, address indexed to);

    modifier onlyLZNotPaused() {
        require(!lzPaused, 'LZ_PAUSED');
        _;
    }

    constructor(address _ccipClient, address _endpoint, address _initialOwner)
        MTokenMessagerBase(_ccipClient) OApp(_endpoint, _initialOwner) Ownable(_initialOwner) {

    }

    function setLZPaused(bool isPaused) public onlyOwner {
        lzPaused = isPaused;
    }

    // lz OApp receive implementation
    function _lzReceive(
        Origin calldata, // _origin
        bytes32 _guid,
        bytes calldata payload,
        address,  // Executor address as specified by the OApp.
        bytes calldata  // Any extra data or options to trigger on receipt.
    ) internal override onlyLZNotPaused {
        // src sender check already made in OApp.
        ICCIPClient(ccipClient).ccReceive(payload);
        emit CCReceiveLZ(_guid, payload);
    }

    function lzSendTokenToChain(
        uint32 _dstEid,
        address recipient,
        uint value,
        bytes calldata _options
    ) external payable onlyLZNotPaused returns (bytes32 messageId) {
        bytes memory _data = ICCIPClient(ccipClient).ccSendToken(
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
        bytes memory _data = ICCIPClient(ccipClient).ccSendMintBudget(value);
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

    function calculateSendTokenFeeForLZ(
        uint32 _dstEid, // Destination chain's endpoint ID.
        address sender,
        address recipient,
        uint value,
        bytes calldata _options // Message execution options
    )
    public
    view
    returns (uint256 nativeFee)
    {
        bytes memory _data = ICCIPClient(ccipClient).msgOfCcSendToken(
            sender,
            recipient,
            value
        );
        MessagingFee memory fee = _quote(_dstEid, _data, _options, false);
        return fee.nativeFee;
    }

    function calculateSendMintBudgetFeeForLZ(
        uint32 _dstEid, // Destination chain's endpoint ID.
        uint112 value,
        bytes calldata _options
    )
    public
    view
    returns (uint256 nativeFee)
    {
        bytes memory _data = ICCIPClient(ccipClient).msgOfCcSendMintBudget(value);
        MessagingFee memory fee = _quote(_dstEid, _data, _options, false);
        return fee.nativeFee;
    }
}
