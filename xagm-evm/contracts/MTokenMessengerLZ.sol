// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {OAppUpgradeable, Origin, MessagingFee} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MTokenMessengerBaseUpgradeable} from "./MTokenMessengerBaseUpgradeable.sol";
import {ICCClient} from "./interfaces/ICCClient.sol";
import {TimeLockerUpgradeable} from "./TimeLockerUpgradeable.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract MTokenMessengerLZ is MTokenMessengerBaseUpgradeable, OAppUpgradeable {
    struct MsgLzStorage {
        bool lzPaused;
        mapping(uint64 eid => uint8 addrLen) eidToAddrLen;
    }

    bytes32 constant OP_LZ_UNPAUSE = keccak256("OP_LZ_UNPAUSE");
    bytes32 constant OP_LZ_ADD_PEER = keccak256("OP_LZ_ADD_PEER");

    // namespace="mtokenmessengerlz.storage.eidtoaddrlen"
    // keccak256(abi.encode(uint256(keccak256(abi.encodePacked(namespace))) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MSGLZ_STORAGE_LOCATION =
        0xa7de46fd53e49d8e70fc58b68ffbf0484ff2aefa7464a0e32d9992ae843a9200;

    function _getMsgLzStorage() internal pure returns (MsgLzStorage storage $) {
        assembly {
            $.slot := MSGLZ_STORAGE_LOCATION
        }
    }

    event CCReceiveLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendTokenLZ(bytes32 indexed messageID, bytes messageData);
    event CCSendMintBudgetLZ(bytes32 indexed messageID, bytes messageData);
    event LZPaused();
    event LZUnpauseRequest(uint64 et);
    event LZUnpauseEffected();
    event LZAddPeerEffected(uint32 indexed eid, bytes32 peer, uint8 addrLen);
    event LZPeerRemoved(uint32 indexed eid);
    event LZAddPeerRequest(uint32 indexed eid, bytes32 peer, uint8 addrLen, uint64 et);

    error InvalidRecipientLength(uint8 expected, uint8 actual);
    error LZNotPaused();
    error UseLzAddPeer();

    modifier onlyLZNotPaused() {
        MsgLzStorage storage $ = _getMsgLzStorage();
        require(!$.lzPaused, "LZ_PAUSED");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function initialize(
        address _ccClient,
        address _initialOwner
    ) public initializer {
        __MTokenMessengerLZ_init(_ccClient, _initialOwner);
    }

    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function __MTokenMessengerLZ_init(
        address _ccClient,
        address _initialOwner
    ) internal onlyInitializing {
        __OApp_init(_initialOwner);
        __MTokenMessengerBase_init(_ccClient, _initialOwner);
    }

    function transferOwnership(address newOwner) public override(OwnableUpgradeable, TimeLockerUpgradeable) {
        TimeLockerUpgradeable.transferOwnership(newOwner);
    }

    function renounceOwnership() public override(OwnableUpgradeable, TimeLockerUpgradeable) {
        TimeLockerUpgradeable.renounceOwnership();
    }

    function lzPaused() public view returns (bool) {
        MsgLzStorage storage $ = _getMsgLzStorage();
        return $.lzPaused;
    }

    function lzPause() public onlyOwner {
        // clear any pending lzUnpause request so it cannot outlive this pause:
        // a request pre-planted (or matured during a previous pause) must not
        // be executable right after a new emergency pause, which would bypass
        // the unpause delay window entirely
        revoke(OP_LZ_UNPAUSE);
        MsgLzStorage storage $ = _getMsgLzStorage();
        $.lzPaused = true;
        emit LZPaused();
    }

    function lzUnpause() public onlyOwner {
        MsgLzStorage storage $ = _getMsgLzStorage();
        // an unpause request may only be created (and executed) while actually
        // paused — otherwise the owner could pre-plant a matured request during
        // normal operation and instantly defeat a future emergency pause
        if (!$.lzPaused) {
            revert LZNotPaused();
        }
        uint64 et = ensureDelay(OP_LZ_UNPAUSE, 0, delay);
        if (et == 0) {
            $.lzPaused = false;
            emit LZUnpauseEffected();
        } else {
            emit LZUnpauseRequest(et);
        }
    }

    function revokeLzUnpause() public onlyOwner {
        revoke(OP_LZ_UNPAUSE);
    }

    // disabled: setPeer alone would leave eidToAddrLen out of sync, use lzAddPeer instead
    function setPeer(uint32, bytes32) public pure override {
        revert UseLzAddPeer();
    }

    // Granting/changing a peer is risk-expanding (it can send messages that mint
    // on this chain), so it goes through the normal `delay` before taking effect
    // (two-call pattern, same as mintTo). Keyed by eid alone so lzRemovePeer can
    // always locate and revoke a pending add without needing to know its peer/addrLen.
    function lzAddPeer(
        uint32 _eid,
        bytes32 _peer,
        uint8 _addrLen
    ) public onlyOwner {
        uint64 et = ensureDelay(_lzAddPeerReqHash(_eid), _lzAddPeerVal(_peer, _addrLen), delay);
        if (et == 0) {
            super.setPeer(_eid, _peer);
            MsgLzStorage storage $ = _getMsgLzStorage();
            $.eidToAddrLen[_eid] = _addrLen;
            emit LZAddPeerEffected(_eid, _peer, _addrLen);
        } else {
            emit LZAddPeerRequest(_eid, _peer, _addrLen, et);
        }
    }

    function revokeLzAddPeer(uint32 _eid) public onlyOwner {
        revoke(_lzAddPeerReqHash(_eid));
    }

    // Removing a peer is a safety action and takes effect immediately, unlike lzAddPeer.
    function lzRemovePeer(uint32 _eid) public onlyOwner {
        // clear any pending add request so it cannot mature right after removal
        // and silently re-establish the peer, bypassing the intent of this safety action
        revoke(_lzAddPeerReqHash(_eid));
        super.setPeer(_eid, bytes32(0));
        MsgLzStorage storage $ = _getMsgLzStorage();
        $.eidToAddrLen[_eid] = 0;
        emit LZPeerRemoved(_eid);
    }

    function _lzAddPeerReqHash(uint32 _eid) private pure returns (bytes32) {
        return keccak256(abi.encode(OP_LZ_ADD_PEER, _eid));
    }

    // fingerprints (peer, addrLen) into the ensureDelay value slot (uint160), since
    // _peer (bytes32) cannot be packed there directly; collision risk is negligible
    function _lzAddPeerVal(bytes32 _peer, uint8 _addrLen) private pure returns (uint160) {
        return uint160(uint256(keccak256(abi.encode(_peer, _addrLen))));
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
        ICCClient(ccClient).ccReceive(payload);
        emit CCReceiveLZ(_guid, payload);
    }

    function lzSendTokenToChain(
        uint32 _dstEid,
        bytes calldata recipient,
        uint256 value,
        bytes calldata _options
    ) external payable onlyLZNotPaused returns (bytes32 messageId) {
        MsgLzStorage storage $ = _getMsgLzStorage();
        uint8 dstAddrLen = $.eidToAddrLen[_dstEid];
        if (dstAddrLen != 0 && recipient.length != dstAddrLen) {
            revert InvalidRecipientLength(dstAddrLen, uint8(recipient.length));
        }

        bytes memory _data = ICCClient(ccClient).ccSendToken(
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
        bytes memory _data = ICCClient(ccClient).ccSendMintBudget(value, msg.sender);
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
        uint256 value,
        bytes calldata _options // Message execution options
    ) public view returns (uint256 nativeFee) {
        bytes memory _data = ICCClient(ccClient).msgOfCcSendToken(
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
        bytes memory _data = ICCClient(ccClient).msgOfCcSendMintBudget(value);
        MessagingFee memory fee = _quote(_dstEid, _data, _options, false);
        return fee.nativeFee;
    }
}
