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

    event SetReserveFeedRequest(address oldAddr, address newAddr, uint64 et);
    event SetReserveFeedEffected(address newAddr);
    event SetFallbackFeedRequest(address oldAddr, address newAddr, uint64 et);
    event SetFallbackFeedEffected(address newAddr);
    event SetFeeCollectorRequest(address oldAddr, address newAddr, uint64 et);
    event SetFeeCollectorEffected(address newAddr);
    event ReconcileSupply(uint64 lastReconcileTime, uint64 thisReconcileTime, uint256 amount);
    error TooEarlyToReconcile();
    error MintBudgetNotZero();

    error NotFeeCollector(address addr);
    error ReserveNotEnough(int256 maxOzAmount, uint256 ozAmount);

    modifier onlyFeeCollector() {
        if (msg.sender != feeCollector) {
            revert NotFeeCollector(msg.sender);
        }
        _;
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
        uint64 et = etNextReserveFeed;
        if (addr == nextReserveFeed && et != 0 && et < block.timestamp) {
            reserveFeed = addr;
            emit SetReserveFeedEffected(addr);
        } else {
            nextReserveFeed = addr;
            etNextReserveFeed = uint64(block.timestamp) + delay;
            emit SetReserveFeedRequest(reserveFeed, addr, etNextReserveFeed);
        }
    }

    function setFallbackFeed(address addr) public onlyOwner {
        _checkZeroAddress(addr);
        uint64 et = etNextFallbackFeed;
        if (addr == nextFallbackFeed && et != 0 && et < block.timestamp) {
            fallbackFeed = addr;
            emit SetFallbackFeedEffected(addr);
        } else {
            nextFallbackFeed = addr;
            etNextFallbackFeed = uint64(block.timestamp) + delay;
            emit SetFallbackFeedRequest(fallbackFeed, addr, etNextFallbackFeed);
        }
    }

    function setFeeCollector(address addr) public onlyOwner {
        _checkZeroAddress(addr);
        uint64 et = etNextFeeCollector;
        if (addr == nextFeeCollector && et != 0 && et < block.timestamp) {
            feeCollector = addr;
            emit SetFeeCollectorEffected(addr);
        } else {
            nextFeeCollector = addr;
            etNextFeeCollector = uint64(block.timestamp) + delay;
            emit SetFeeCollectorRequest(feeCollector, addr, etNextFeeCollector);
        }
    }

    function revokeNextReserveFeed() public onlyRevoker {
        etNextReserveFeed = 0;
    }

    function revokeNextFallbackFeed() public onlyRevoker {
        etNextFallbackFeed = 0;
    }

    function revokeFeeCollector() public onlyRevoker {
        etNextFeeCollector = 0;
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

    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        _increaseMintBudget(mintBudgetDelta);
    }

    function _increaseMintBudget(uint112 mintBudgetDelta) private {
        uint112 newTokenObligation = totalTokenObligation + mintBudgetDelta;
        uint256 ozAmount = (newTokenObligation * ozPerToken()) / OZ_RATIO_BASE;
        int256 maxOzAmount = getReserve();
        if (int256(ozAmount) > maxOzAmount) {
            revert ReserveNotEnough(maxOzAmount, ozAmount);
        }
        mintBudget += mintBudgetDelta;
        totalTokenObligation = newTokenObligation;
    }

    function decreaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
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
}
