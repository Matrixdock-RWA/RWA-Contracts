// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MToken} from "./MToken.sol";

// this contract will be deployed on Ethereum
contract MTokenMain is MToken {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 constant ORACLE_OFFLINE_THRESHOLD = 3 days;

    // generous upper bound: the longest tx identifier in use is Solana's 64-byte
    // signature, and the check only exists to keep an unbounded blob out of calldata
    uint256 constant MAX_SRC_TX_HASH_LEN = 128;

    event ReconcileSupply(uint64 lastReconcileTime, uint64 thisReconcileTime, uint256 amount);
    event ConfigMintBudgetPeer(uint32 indexed eid, bool enabled);
    event AllocateMintBudgetToChain(
        address indexed caller,
        uint32 indexed dstEid,
        uint112 deltaAmount,
        uint112 totalAllocatedAmount,
        uint112 totalTokenObligation
    );
    event ReclaimMintBudgetFromChain(
        address indexed caller,
        uint32 indexed srcEid,
        uint112 deltaAmount,
        uint112 totalReturnedAmount,
        uint112 totalTokenObligation,
        bytes srcTxHash // recorded as given; the contract does not verify it
    );

    error TooEarlyToReconcile();
    error MintBudgetNotZero();

    error NotFeeCollector(address addr);
    error ReserveNotEnough(int256 maxOzAmount, uint256 ozAmount);
    error MintBudgetPeerNotSet(uint32 eid);
    error TokenObligationBelowFloor(uint256 totalTokenObligation, uint256 floor);
    error InvalidSrcTxHash(uint256 length);

    modifier onlyFeeCollector() {
        if (msg.sender != feeCollector) {
            revert NotFeeCollector(msg.sender);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed,
        uint64 _annualFeeRate,
        uint64 _ozPerTokenBase,
        address _feeCollector
    ) public initializer {
        __MTOKENMAIN_init(
            name,
            symbol,
            _owner,
            _operator,
            _reserveFeed,
            _annualFeeRate,
            _ozPerTokenBase,
            _feeCollector
        );
    }

    function __MTOKENMAIN_init(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed,
        uint64 _annualFeeRate,
        uint64 _ozPerTokenBase,
        address _feeCollector
    ) internal onlyInitializing {
        __MTOKEN_init(
            name,
            symbol,
            _owner,
            _operator,
            _annualFeeRate,
            _ozPerTokenBase
        );
        reserveFeed = _reserveFeed;
        feeCollector = _feeCollector;
    }

    function setReserveFeed(address addr) public onlyOwner {
        _checkZeroAddress(addr);
        if (ensureGovDelay(OP_SET_RESERVE_FEED, uint160(reserveFeed), uint160(addr))) {
            reserveFeed = addr;
        }
    }

    function setFallbackFeed(address addr) public onlyOwner {
        _checkZeroAddress(addr);
        if (ensureGovDelay(OP_SET_FALLBACK_FEED, uint160(fallbackFeed), uint160(addr))) {
            fallbackFeed = addr;
        }
    }

    function setFeeCollector(address addr) public onlyOwner {
        _checkZeroAddress(addr);
        if (ensureGovDelay(OP_SET_FEE_COLLECTOR, uint160(feeCollector), uint160(addr))) {
            feeCollector = addr;
        }
    }

    function getReserve() private view returns (int256) {
        // prettier-ignore
        (
            /*uint80 roundID*/,
            int256 reserveFromFeed,
            /*uint256 startedAt*/,
            uint256 updatedAt,
            /*uint80 answeredInRound*/
        ) = AggregatorV3Interface(reserveFeed).latestRoundData();

        if (updatedAt + ORACLE_OFFLINE_THRESHOLD < block.timestamp) {
            // use fallback reserve feed
            // note: fallback feed doesn't require strong timeliness guarantees
            // hence doesn't use staleness check by design
            (, reserveFromFeed, , , ) = AggregatorV3Interface(fallbackFeed)
                .latestRoundData();
        }

        return reserveFromFeed;
    }

    // both of these serve Ethereum's own mintBudget only, and both are gated by the
    // global pause: increase because it is risk-raising, decrease because its upstream
    // is this chain's own redemption, which the pause already stops — so including it
    // closes no exit that the pause left open (unlike the side chains' return paths)
    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator whenNotPaused {
        _increaseMintBudget(mintBudgetDelta);
    }

    function _increaseMintBudget(uint112 mintBudgetDelta) private {
        _increaseTokenObligation(mintBudgetDelta);
        mintBudget += mintBudgetDelta;
    }

    function _increaseTokenObligation(uint112 delta) private {
        uint112 newTokenObligation = totalTokenObligation + delta;
        uint256 ozAmount = (newTokenObligation * ozPerToken()) / OZ_RATIO_BASE;
        int256 maxOzAmount = getReserve();
        if (int256(ozAmount) > maxOzAmount) {
            revert ReserveNotEnough(maxOzAmount, ozAmount);
        }
        totalTokenObligation = newTokenObligation;
    }

    function decreaseMintBudget(uint112 mintBudgetDelta) public onlyOperator whenNotPaused {
        uint112 newTokenObligation = totalTokenObligation - mintBudgetDelta;
        mintBudget -= mintBudgetDelta;
        totalTokenObligation = newTokenObligation;
    }

    // mint fee tokens to the fee collector
    function reconcileSupply(uint112 amount) public onlyFeeCollector {
        _checkZeroValue(amount);
        if (mintBudget > 0) {
            revert MintBudgetNotZero();
        }

        // check and update lastReconcileTime
        uint64 _lastReconcileTime = lastReconcileTime;
        uint64 newReconcileTime = currentDayStartTime();
        if (_lastReconcileTime == newReconcileTime) {
            revert TooEarlyToReconcile();
        }
        lastReconcileTime = newReconcileTime;

        _increaseMintBudget(amount);
        mintBudget = mintBudget - amount;
        _mint(feeCollector, amount); // mint fee tokens
        emit ReconcileSupply(_lastReconcileTime, newReconcileTime, amount);
    }

    //-------------
    // global mintBudget management

    // enables/disables a chain as a target of allocateMintBudgetToChain
    function configMintBudgetPeer(uint32 eid, bool enabled) public onlyOwner {
        _checkZeroValue(eid);
        mintBudgetMap[eid].enabled = enabled;
        emit ConfigMintBudgetPeer(eid, enabled);
    }

    // grants mintBudget to another chain, raising totalTokenObligation by the new cumulative
    // total's delta. Ethereum's own mintBudget is left alone: the grant is booked purely as an
    // obligation, and the receiving chain credits its local mintBudget itself.
    function allocateMintBudgetToChain(
        uint32 dstEid,
        uint112 newTotalAllocatedAmount
    ) public onlyOperator whenNotPaused {
        MintBudgetInfo storage mbInfo = mintBudgetMap[dstEid];
        if (! mbInfo.enabled) {
            revert MintBudgetPeerNotSet(dstEid);
        }

        uint112 deltaAmount = _advanceAllocated(mbInfo, newTotalAllocatedAmount);
        _increaseTokenObligation(deltaAmount);

        emit AllocateMintBudgetToChain(msg.sender, dstEid, deltaAmount, newTotalAllocatedAmount,
            totalTokenObligation);
    }

    // books mintBudget returned by another chain, lowering totalTokenObligation by the new
    // cumulative total's delta. Risk-reducing, so gated by neither whenNotPaused nor the peer
    // allowlist: the upstream is a side-chain redemption Ethereum can neither pause nor
    // un-register, and a disabled or never-registered chain may still hold earlier grants that
    // only this path can book back.
    function reclaimMintBudgetFromChain(
        uint32 srcEid,
        uint112 newTotalReturnedAmount,
        bytes calldata srcTxHash
    ) public onlyMintBudgetSubmitter {
        _checkSrcTxHash(srcTxHash);

        MintBudgetInfo storage mbInfo = mintBudgetMap[srcEid];
        uint112 deltaAmount = _advanceReturned(mbInfo, newTotalReturnedAmount);
        uint112 newTokenObligation = totalTokenObligation - deltaAmount;

        uint256 floor = totalSupply() + mintBudget;
        if (newTokenObligation < floor) {
            revert TokenObligationBelowFloor(newTokenObligation, floor);
        }

        totalTokenObligation = newTokenObligation;
        emit ReclaimMintBudgetFromChain(msg.sender, srcEid, deltaAmount, newTotalReturnedAmount,
            newTokenObligation, srcTxHash);
    }

    // the source-chain tx that authorized a mintBudget submission: variable-length because
    // chains disagree on tx id size (32 bytes on EVM/Sui/Stellar, 64 on Solana), and only
    // recorded — the contract can't read another chain, so verification is off-chain.
    function _checkSrcTxHash(bytes calldata srcTxHash) private pure {
        if (srcTxHash.length == 0 || srcTxHash.length > MAX_SRC_TX_HASH_LEN) {
            revert InvalidSrcTxHash(srcTxHash.length);
        }
    }
}
