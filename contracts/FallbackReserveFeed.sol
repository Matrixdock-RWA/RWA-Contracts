// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FallbackReserveFeed is Ownable, AggregatorV3Interface {
    int256 public reserve;
    uint64 public updatedAt;
    uint80 public roundId;

    event ReserveSet(uint80 indexed roundId, int256 newReserve);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "MatrixDock Bullion Reserve";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function setReserve(int256 _reserve) public onlyOwner {
        reserve = _reserve;
        updatedAt = uint64(block.timestamp);
        roundId = roundId + 1;
        emit ReserveSet(roundId, _reserve);
    }

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId_,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        require(_roundId == roundId, "NO_DATA");
        return latestRoundData();
    }

    function latestRoundData()
        public
        view
        returns (
            uint80 /*roundId*/,
            int256 /*answer*/,
            uint256 /*startedAt*/,
            uint256 /*updatedAt*/,
            uint80 /*answeredInRound*/
        )
    {
        return (roundId, reserve, uint(updatedAt), uint(updatedAt), roundId);
    }
}
