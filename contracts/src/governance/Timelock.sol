// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Goldbench Timelock
/// @notice OpenZeppelin TimelockController with a hard 48h floor on the delay. Holds DEFAULT_ADMIN_ROLE on every
///         Goldbench contract after deployment. ProjectTokenHooks is granted PROPOSER_ROLE once the project token is
///         live so that staker votes can be scheduled (still subject to the full 48h delay and owner cancellation).
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    uint256 private _delay;

    error DelayBelowFloor(uint256 delay);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor(minDelay);
        _delay = minDelay;
    }

    function getMinDelay() public view override returns (uint256) {
        return _delay;
    }

    /// @dev Delay changes go through the timelock itself; the 48h floor can never be lowered.
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        if (newDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor(newDelay);
        emit MinDelayChange(_delay, newDelay);
        _delay = newDelay;
    }
}
