// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Chainlink proxy palsu: harga diset manual, `updatedAt` = saat set.
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    address public aggregator = address(this); // proxy "asli" punya aggregator non-nol

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        set(answer_);
    }

    function set(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setAggregator(address a) external {
        aggregator = a;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
