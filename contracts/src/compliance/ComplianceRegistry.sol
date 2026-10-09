// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IComplianceRegistry} from "../interfaces/IGoldbench.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: while disabled every account is allowed for every action.
///         When enabled, an action is allowed if the account is allowlisted globally or for that specific action.
///         Vaults consult it on deposit/mint, share transfers and cash withdrawals to a third party. Exits to self
///         (redeem / redeemInKind with receiver == owner) are never gated so users can always leave.
contract ComplianceRegistry is GoldbenchAccess, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant ANY_ACTION = bytes32(0);
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address account => mapping(bytes32 action => bool)) public allowed;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bytes32 indexed action, bool allowed);

    error BatchTooLarge();

    constructor(address admin) GoldbenchAccess(admin) {}

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setAllowed(address[] calldata accounts, bytes32 action, bool ok) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]][action] = ok;
            emit AllowedSet(accounts[i], action, ok);
        }
    }

    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled) return true;
        return allowed[account][ANY_ACTION] || allowed[account][action];
    }
}
