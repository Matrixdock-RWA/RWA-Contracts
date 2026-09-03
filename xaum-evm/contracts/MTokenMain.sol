// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MToken} from "./MToken.sol";

// this contract will be deployed on Ethereum
contract MTokenMain is MToken {
    using SafeCast for uint256;

    uint256 constant ORACLE_OFFLINE_THRESHOLD = 2 days;

    error ReserveNotEnough(int max, int amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed
    ) public initializer {
        __MTOKENMAIN_init(name, symbol, _owner, _operator, _reserveFeed);
    }

    function __MTOKENMAIN_init(
        string memory name,
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed
    ) internal onlyInitializing {
        __MTOKEN_init(name, symbol, _owner, _operator);
        reserveFeed = _reserveFeed;
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

    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        uint256 _usedReserve = usedReserve + mintBudgetDelta;
        // prettier-ignore
        (
            /*uint80 roundID*/,
            int reserveFromFeed,
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

        if (int(_usedReserve) > reserveFromFeed) {
            revert ReserveNotEnough(reserveFromFeed, int(_usedReserve));
        }
        mintBudget += mintBudgetDelta;
        usedReserve = _usedReserve.toUint112();
    }

    function decreaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        uint256 _usedReserve = usedReserve - mintBudgetDelta;
        mintBudget -= mintBudgetDelta;
        usedReserve = _usedReserve.toUint112();
    }
}
