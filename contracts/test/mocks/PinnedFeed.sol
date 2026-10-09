// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev LOCAL FORK DEMO ONLY (never deployed to a live chain). Its runtime code is written over a real Chainlink proxy
///      on an anvil fork with `anvil_setCode` after PriceHistory has been seeded from the real rounds, so the demo can
///      run during simulated market hours: it re-publishes the feed's *current* answer with a fresh timestamp.
///      Storage: slot0 = answer, slot1 = updatedAt, slot2 = roundId, slot3 = decimals.
contract PinnedFeed {
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal roundId;
    uint8 internal dec;

    function decimals() external view returns (uint8) {
        return dec;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (id, answer, updatedAt, updatedAt, id);
    }
}
