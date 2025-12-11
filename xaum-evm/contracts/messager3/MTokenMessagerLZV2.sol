// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OAppUpgradeable, Origin, MessagingFee} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MTokenMessagerBaseUpgradeable} from "./MTokenMessagerBaseUpgradeable.sol";
import {ICCClientV2} from "../interfaces/ICCClientV2.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract MTokenMessagerLZV2 is MTokenMessagerBaseUpgradeable, OAppUpgradeable {
    bool public lzPaused;

    event CCReceiveLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendTokenLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudgetLZ(bytes32 indexed messageID, bytes messageData);
    event LZPaused(bool isPaused);

    modifier onlyLZNotPaused() {
        require(!lzPaused, "LZ_PAUSED");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(
        address _ccClient,
        address _initialOwner
    ) public initializer {
        __MTokenMessagerLZV2_init(_ccClient, _initialOwner);
    }

    function __MTokenMessagerLZV2_init(
        address _ccClient,
        address _initialOwner
    ) internal onlyInitializing {
        __OApp_init(_initialOwner);
        __MTokenMessagerBase_init(_ccClient, _initialOwner);
    }

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
        ICCClientV2(ccClient).ccReceive(payload);
        emit CCReceiveLZ(_guid, payload);
    }

    function lzSendTokenToChain(
        uint32 _dstEid,
        bytes calldata recipient,
        uint value,
        bytes calldata _options
    ) external payable onlyLZNotPaused returns (bytes32 messageId) {
        bytes memory _data = ICCClientV2(ccClient).ccSendToken(
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
        bytes memory _data = ICCClientV2(ccClient).ccSendMintBudget(value);
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
        bytes calldata recipient,
        uint value,
        bytes calldata _options // Message execution options
    ) public view returns (uint256 nativeFee) {
        bytes memory _data = ICCClientV2(ccClient).msgOfCcSendToken(
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
