// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

contract FakeAggregatorV3 {
    int256 public reserve;

    constructor(int256 _reserve) {
        reserve = _reserve;
    }

    function setReserve(int256 _reserve) public {
        reserve = _reserve;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        answer = reserve;
    }
}
