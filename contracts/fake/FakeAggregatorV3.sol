// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

contract FakeAggregatorV3 {
    int256 public reserve;
    uint256 public updatedAt;

    constructor(int256 _reserve) {
        reserve = _reserve;
    }

    function setReserve(int256 _reserve) public {
        reserve = _reserve;
    }

    function setUpdatedAt(uint256 _ts) public {
        updatedAt = _ts;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 /*roundId*/,
            int256 /*answer*/,
            uint256 /*startedAt*/,
            uint256 /*updatedAt*/,
            uint80 /*answeredInRound*/
        )
    {
        // answer = reserve;
        uint256 _updatedAt = updatedAt;
        if (_updatedAt == 0) {
            _updatedAt = block.timestamp - 10 minutes;
        }
        return (0, reserve, _updatedAt, _updatedAt, 0);
    }
}
