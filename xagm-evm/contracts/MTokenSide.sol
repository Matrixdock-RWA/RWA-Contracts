// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./MToken.sol";

// this contract will be deployed on L2s
contract MTokenSide is MToken {
    event SetLocalEid(uint32 eid);
    event ClaimMintBudgetFromEth(
        address indexed caller,
        uint32 indexed dstEid, // always this chain's own eid; indexed for uniform per-chain queries
        uint112 deltaAmount,
        uint112 totalAllocatedAmount,
        bytes srcTxHash // recorded as given; the contract does not verify it
    );
    event ReturnMintBudgetToEth(
        address indexed caller,
        uint32 indexed localEid, // this chain's own eid; indexed for uniform per-chain queries
        uint112 deltaAmount,
        uint112 totalReturnedAmount
    );

    error LocalEidNotSet();
    error LocalEidLocked(uint32 localEid, uint32 requested);
    error WrongTargetChain(uint32 localEid, uint32 dstEid);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        uint64 _feeRatePerYear,
        uint64 _ozPerTokenBase
    ) public initializer {
        __MTOKEN_init(
            name,
            symbol,
            _owner,
            _operator,
            _feeRatePerYear,
            _ozPerTokenBase
        );
    }

    //-------------
    // global mintBudget management

    // declares this chain's own eid; changeable only until mintBudget has moved under it
    function setLocalEid(uint32 _localEid) public onlyOwner {
        _checkZeroValue(_localEid);

        uint32 _currLocalEid = localEid;
        MintBudgetInfo storage currInfo = mintBudgetMap[_currLocalEid];
        if (_localEid != _currLocalEid &&
                (currInfo.totalAllocatedAmount != 0 || currInfo.totalReturnedAmount != 0)) {
            revert LocalEidLocked(_currLocalEid, _localEid);
        }

        localEid = _localEid;
        emit SetLocalEid(_localEid);
    }

    // reads this chain's own eid, reverting if it has not been set yet
    function _getLocalEid() internal view returns (uint32 _localEid) {
        _localEid = localEid;
        if (_localEid == 0) {
            revert LocalEidNotSet();
        }
    }

    // credits mintBudget granted by Ethereum, by the new cumulative total's delta.
    // dstEid is misdelivery protection, not routing: a submission prepared for another side
    // chain carries that chain's eid and fails here instead of being taken for this chain's
    // own cumulative value.
    function claimMintBudgetFromEth(
        uint32 dstEid,
        uint112 newTotalAllocatedAmount,
        bytes calldata srcTxHash
    ) public onlyMintBudgetSubmitter whenNotPaused {
        uint32 _localEid = _getLocalEid();
        if (dstEid != _localEid) {
            revert WrongTargetChain(_localEid, dstEid);
        }
        _checkSrcTxHash(srcTxHash);

        MintBudgetInfo storage mintBudgetInfo = mintBudgetMap[_localEid];
        uint112 deltaAmount = _advanceAllocated(mintBudgetInfo, newTotalAllocatedAmount);
        mintBudget += deltaAmount;
        emit ClaimMintBudgetFromEth(msg.sender, _localEid, deltaAmount, newTotalAllocatedAmount, srcTxHash);
    }

    // returns mintBudget to Ethereum, by the new cumulative total's delta. Risk-reducing (it
    // only ever shrinks this chain's mintBudget), so unlike claimMintBudgetFromEth it is not
    // gated by whenNotPaused — pausing must not block the one path that lowers this chain's
    // own mint capacity.
    function returnMintBudgetToEth(
        uint112 newTotalReturnedAmount
    ) public onlyOperator {
        uint32 _localEid = _getLocalEid();

        MintBudgetInfo storage mintBudgetInfo = mintBudgetMap[_localEid];
        uint112 deltaAmount = _advanceReturned(mintBudgetInfo, newTotalReturnedAmount);
        _checkMintBudget(deltaAmount);
        mintBudget -= deltaAmount;

        emit ReturnMintBudgetToEth(msg.sender, _localEid, deltaAmount, newTotalReturnedAmount);
    }
}
