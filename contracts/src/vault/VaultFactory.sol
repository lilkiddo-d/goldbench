// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RotationVault} from "./RotationVault.sol";

interface IRegistrar {
    function registerVault(address vault) external;
}

interface IHooksRegistrar {
    function addVault(address vault) external;
}

/// @title VaultFactory
/// @notice Deploys RotationVault instances as EIP-1167 clones of a single audited implementation and wires them into
///         SignalEngine (VAULT_ROLE), FeeCollector and ProjectTokenHooks. Admin = Timelock after deployment.
contract VaultFactory is AccessControl {
    bytes32 internal constant VAULT_ROLE = keccak256("VAULT_ROLE");

    address public immutable implementation;
    AccessControl public immutable engine;
    IRegistrar public immutable feeCollector;
    IHooksRegistrar public immutable hooks;

    address[] internal _vaults;

    event VaultCreated(address indexed vault, string name, string symbol, uint16 stockCapBps);

    error ZeroAddress();

    constructor(address admin, address implementation_, AccessControl engine_, IRegistrar feeCollector_, IHooksRegistrar hooks_) {
        if (
            admin == address(0) || implementation_ == address(0) || address(engine_) == address(0)
                || address(feeCollector_) == address(0) || address(hooks_) == address(0)
        ) revert ZeroAddress();
        implementation = implementation_;
        engine = engine_;
        feeCollector = feeCollector_;
        hooks = hooks_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createVault(RotationVault.InitParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address vault) {
        vault = Clones.clone(implementation);
        _vaults.push(vault);
        emit VaultCreated(vault, p.name, p.symbol, p.stockCapBps);
        RotationVault(vault).initialize(p);
        engine.grantRole(VAULT_ROLE, vault);
        feeCollector.registerVault(vault);
        hooks.addVault(vault);
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }
}
