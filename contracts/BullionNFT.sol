// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IMToken.sol";

contract BullionNFT is
    ERC721Upgradeable,
    EIP712Upgradeable,
    OwnableUpgradeable
{
    address public mtokenContract;
    // a certain amount of mtoken can be packed into a NFT
    mapping(uint nft => uint packedAmount) public packedCoins;

    // lock NFTs to avoid accidentally losing them
    mapping(uint => bool) public isLocked;

    string private baseURI;

    // a packSigner endorse the information of a bullion
    address public packSigner;
    address public nextPackSigner;
    uint64 public etNextPackSigner; //effective time

    bytes32 private constant PACK_TYPEHASH =
        keccak256(
            "Pack(address owner,uint256 amount,uint256 bullion,uint256 deadline)"
        );

    event SetPackSignerRequest(address oldAddr, address newAddr, uint64 et);
    event SetPackSignerEffected(address newAddr);
    event LockPlaced(uint indexed _user, bytes reason);
    event LockReleased(uint indexed _user);

    error NotOperator(address);
    error NotRevoker(address);
    error BlockedAccount(address);
    error TokenLocked(uint);
    error TransferToContract();
    error ArgsMismatch();
    error DuplicatedBullion(uint);
    error NoSuchBullion(uint);
    error NotNftOwner(uint, address);
    error SignatureExpired(uint);
    error InvalidSigner(address);

    modifier onlyOperator() {
        if (msg.sender != IMToken(mtokenContract).operator()) {
            revert NotOperator(msg.sender);
        }
        _;
    }

    modifier onlyRevoker() {
        if (msg.sender != IMToken(mtokenContract).revoker()) {
            revert NotRevoker(msg.sender);
        }
        _;
    }

    modifier onlyNotBlocked() {
        _checkBlocked(msg.sender);
        _;
    }

    function _checkBlocked(address addr) private {
        if (IMToken(mtokenContract).isBlocked(addr)) {
            revert BlockedAccount(addr);
        }
    }

    function _checkLocked(uint256 tokenId) private view {
        if (isLocked[tokenId]) {
            revert TokenLocked(tokenId);
        }
    }

    function _ensureBullionNotExist(uint256 bullion) private view {
        if (packedCoins[bullion] != 0) {
            revert DuplicatedBullion(bullion);
        }
    }

    function _getAmount(uint256 bullion) private view returns (uint) {
        uint amount = packedCoins[bullion];
        if (amount == 0) {
            revert NoSuchBullion(bullion);
        }
        return amount;
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address _mtokenContract,
        address _packSigner,
        address _owner
    ) public initializer {
        __BullionNFT_init(name_, symbol_, _mtokenContract, _packSigner, _owner);
    }

    function __BullionNFT_init(
        string memory name_,
        string memory symbol_,
        address _mtokenContract,
        address _packSigner,
        address _owner
    ) internal onlyInitializing {
        __ERC721_init(name_, symbol_);
        __EIP712_init_unchained(symbol_, "1");
        __Ownable_init(_owner);
        mtokenContract = _mtokenContract; // cannot change after init
        packSigner = _packSigner;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string calldata uri) public onlyOperator {
        baseURI = uri;
    }

    function setPackSigner(address addr) public onlyOperator {
        uint64 et = etNextPackSigner;
        uint64 delay = IMToken(mtokenContract).delay();
        if (addr == nextPackSigner && et != 0 && et < block.timestamp) {
            packSigner = addr;
            emit SetPackSignerEffected(addr);
        } else {
            nextPackSigner = addr;
            etNextPackSigner = uint64(block.timestamp) + delay;
            emit SetPackSignerRequest(packSigner, addr, etNextPackSigner);
        }
    }

    function revokeNextPackSigner() public onlyRevoker {
        etNextPackSigner = 0;
    }

    function addToLockedList(
        uint _tokenId,
        bytes memory reason
    ) public onlyOperator {
        isLocked[_tokenId] = true;
        emit LockPlaced(_tokenId, reason);
    }

    function removeFromLockedList(uint _tokenId) public onlyOperator {
        isLocked[_tokenId] = false;
        emit LockReleased(_tokenId);
    }

    // override 'transferFrom' to support blocked users and locked NFTs
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _tokenId
    ) public virtual override onlyNotBlocked {
        _transferCheck(_sender, _recipient, _tokenId);
        return super.transferFrom(_sender, _recipient, _tokenId);
    }

    function _transferCheck(
        address _sender,
        address _recipient,
        uint256 _tokenId
    ) private {
        if (_recipient == address(this)) {
            revert TransferToContract();
        }
        _checkBlocked(_sender);
        _checkLocked(_tokenId);
    }

    function multiTransferFrom(
        address _sender,
        address[] memory _recipients,
        uint256[] memory _tokenIds
    ) public onlyNotBlocked {
        if (_recipients.length != _tokenIds.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            transferFrom(_sender, _recipients[i], _tokenIds[i]);
        }
    }

    function multiSafeTransferFrom(
        address _sender,
        address[] memory _recipients,
        uint256[] memory _tokenIds
    ) public onlyNotBlocked {
        if (_recipients.length != _tokenIds.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            safeTransferFrom(_sender, _recipients[i], _tokenIds[i]);
        }
    }

    // override 'safeTransferFrom' to support blocked users and locked NFTs
    function safeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _tokenId,
        bytes memory data
    ) public virtual override onlyNotBlocked {
        _transferCheck(_sender, _recipient, _tokenId);
        return super.safeTransferFrom(_sender, _recipient, _tokenId, data);
    }

    function multiSafeTransferFrom(
        address _sender,
        address[] memory _recipients,
        uint256[] memory _tokenIds,
        bytes memory data
    ) public onlyNotBlocked {
        if (_recipients.length != _tokenIds.length) {
            revert ArgsMismatch();
        }
        for (uint256 i = 0; i < _recipients.length; i++) {
            safeTransferFrom(_sender, _recipients[i], _tokenIds[i], data);
        }
    }

    //===============

    // the packSigner endorses a bullion to support the customer pack mtoken into NFT
    function packWithSig(
        uint amount,
        uint bullion,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        if (block.timestamp >= deadline) {
            revert SignatureExpired(deadline);
        }
        bytes32 structHash = keccak256(
            abi.encode(PACK_TYPEHASH, msg.sender, amount, bullion, deadline)
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        if (signer != packSigner) {
            revert InvalidSigner(signer);
        }
        IMToken(mtokenContract).pack(msg.sender, amount);
        _ensureBullionNotExist(bullion);
        packedCoins[bullion] = amount;
        _mint(msg.sender, bullion);
    }

    // mint 'amount' MTokens and pack them into a bullion NFT
    function mintAndPack(
        uint amount,
        uint bullion,
        uint nonce
    ) public onlyOperator {
        _ensureBullionNotExist(bullion);
        bool executed = IMToken(mtokenContract).mintTo(
            address(this),
            amount,
            nonce
        );
        if (executed) {
            packedCoins[bullion] = amount;
            _mint(msg.sender, bullion);
        }
    }

    // unpack operator's bullion NFT and burn the MTokens in it
    function unpackAndRedeem(
        uint bullion,
        address customer,
        bytes calldata data
    ) public onlyOperator {
        uint amount = _getAmount(bullion);
        if (ownerOf(bullion) != msg.sender) {
            revert NotNftOwner(bullion, msg.sender);
        }
        delete packedCoins[bullion];
        IERC20(mtokenContract).transfer(msg.sender, amount);
        IMToken(mtokenContract).redeem(amount, customer, data);
        _burn(bullion);
    }

    // pack 'amount' of MTokens from operator and mint a 'bullion' NFT
    function pack(uint amount, uint bullion) public onlyOperator {
        IMToken(mtokenContract).pack(msg.sender, amount);
        _ensureBullionNotExist(bullion);
        packedCoins[bullion] = amount;
        _mint(msg.sender, bullion);
    }

    // unpack a bullion NFT and return the MTokens. Can be used by customers.
    function unpack(uint bullion) public {
        uint amount = _getAmount(bullion);
        if (ownerOf(bullion) != msg.sender) {
            revert NotNftOwner(bullion, msg.sender);
        }
        delete packedCoins[bullion];
        IMToken(mtokenContract).unpack(msg.sender, amount);
        _burn(bullion);
    }

    function batchMintAndPack(
        uint[] calldata amounts,
        uint[] calldata bullions,
        uint nonce
    ) public onlyOperator {
        if (amounts.length != bullions.length) {
            revert ArgsMismatch();
        }
        for (uint i = 0; i < bullions.length; i++) {
            mintAndPack(amounts[i], bullions[i], nonce);
        }
    }

    function batchUnpackAndRedeem(
        uint[] calldata bullions,
        address customer,
        bytes calldata data
    ) public onlyOperator {
        for (uint i = 0; i < bullions.length; i++) {
            unpackAndRedeem(bullions[i], customer, data);
        }
    }

    function batchPack(
        uint[] calldata amounts,
        uint[] calldata bullions
    ) public onlyOperator {
        if (amounts.length != bullions.length) {
            revert ArgsMismatch();
        }
        for (uint i = 0; i < bullions.length; i++) {
            pack(amounts[i], bullions[i]);
        }
    }

    function batchUnpack(uint[] calldata bullions) public onlyOperator {
        for (uint i = 0; i < bullions.length; i++) {
            unpack(bullions[i]);
        }
    }
}

contract BullionNFT_UT is BullionNFT {
    function safeTransferFrom2(
        address _sender,
        address _recipient,
        uint256 _tokenId,
        bytes memory data
    ) public {
        super.safeTransferFrom(_sender, _recipient, _tokenId, data);
    }

    function multiSafeTransferFrom2(
        address _sender,
        address[] memory _recipients,
        uint256[] memory _tokenIds,
        bytes memory data
    ) public {
        super.multiSafeTransferFrom(_sender, _recipients, _tokenIds, data);
    }
}
