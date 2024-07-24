// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./MToken.sol";

// this contract will be deployed on Ethereum
contract MTokenMain is MToken {
    event SetReserveFeedRequest(address oldAddr, address newAddr, uint64 et);
    event SetReserveFeedEffected(address newAddr);

    error ReserveNotEnough(int max, int amount);

    function initialize(
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed
    ) public initializer {
        __MTOKENMAIN_init(symbol, _owner, _operator, _reserveFeed);
    }

    function __MTOKENMAIN_init(
        string memory symbol,
        address _owner,
        address _operator,
        address _reserveFeed
    ) internal onlyInitializing {
        __MTOKEN_init(symbol, _owner, _operator);
        reserveFeed = _reserveFeed;
    }

    function setReserveFeed(address addr) public onlyOwner {
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

    function revokeNextReserveFeed() public onlyRevoker {
        etNextReserveFeed = 0;
    }

    function increaseMintBudget(uint112 mintBudgetDelta) public onlyOperator {
        uint _usedReserve = usedReserve + mintBudgetDelta;
        // prettier-ignore
        (
            /*uint80 roundID*/,
             int reserveFromFeed ,
            /*uint startedAt*/ ,
            /*uint timestamp*/,
            /*uint80 answeredInRound*/
        ) = AggregatorV3Interface(reserveFeed).latestRoundData();
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
