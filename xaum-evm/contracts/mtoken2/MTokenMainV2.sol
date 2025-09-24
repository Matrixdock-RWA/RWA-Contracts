// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./MToken.sol";

// this contract will be deployed on Ethereum
contract MTokenMain is MToken {
    uint constant ORACLE_OFFLINE_THRESHOLD = 2 days;

    event SetReserveFeedRequest(address oldAddr, address newAddr, uint64 et);
    event SetReserveFeedEffected(address newAddr);
    event SetFallbackFeedRequest(address oldAddr, address newAddr, uint64 et);
    event SetFallbackFeedEffected(address newAddr);

    error ReserveNotEnough(int max, int amount);

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

    function revokeNextReserveFeed() public onlyRevoker {
        etNextReserveFeed = 0;
    }

    function revokeNextFallbackFeed() public onlyRevoker {
        etNextFallbackFeed = 0;
    }

    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        uint _usedReserve = usedReserve + mintBudgetDelta;
        // prettier-ignore
        (
            /*uint80 roundID*/,
            int reserveFromFeed,
            /*uint startedAt*/,
            uint updatedAt,
            /*uint80 answeredInRound*/
        ) = AggregatorV3Interface(reserveFeed).latestRoundData();

        if (updatedAt + ORACLE_OFFLINE_THRESHOLD < block.timestamp) {
            // use fallback reserve feed
            (, reserveFromFeed, , , ) = AggregatorV3Interface(fallbackFeed)
                .latestRoundData();
        }

        if (int(_usedReserve) > reserveFromFeed) {
            revert ReserveNotEnough(reserveFromFeed, int(_usedReserve));
        }
        mintBudget += uint112(mintBudgetDelta);
        usedReserve = uint112(_usedReserve);
    }

    function decreaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        uint _usedReserve = usedReserve - mintBudgetDelta;
        mintBudget -= mintBudgetDelta;
        usedReserve = uint112(_usedReserve);
    }
}
