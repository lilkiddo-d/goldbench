// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title GoldbenchAccess
/// @notice Shared role model. DEFAULT_ADMIN_ROLE is held by the 48h Timelock after deployment.
///         GUARDIAN_ROLE can only pause (fast, defensive). Unpausing requires the admin (Timelock).
abstract contract GoldbenchAccess is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    error ZeroAddress();
    error OutOfBounds(uint256 value, uint256 min, uint256 max);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _checkBounds(uint256 v, uint256 min, uint256 max) internal pure {
        if (v < min || v > max) revert OutOfBounds(v, min, max);
    }
}
