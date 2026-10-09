// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IFeeCollector, IProjectTokenHooks} from "../interfaces/IGoldbench.sol";

/// @title FeeCollector
/// @notice Receives management-fee shares minted by vaults. `distribute` splits them between the treasury and the
///         staker rebate pool in ProjectTokenHooks. While the project token is unset (or nobody stakes) 100% goes
///         to the treasury - the protocol works fully without the token.
contract FeeCollector is GoldbenchAccess, ReentrancyGuard, IFeeCollector {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_REBATE_BPS = 10_000;

    address public treasury;
    IProjectTokenHooks public hooks;
    uint16 public rebateBps = 5000; // share of fees returned to $GBEN stakers once the token is live
    mapping(address vault => bool) public isVault;

    event TreasurySet(address indexed treasury);
    event HooksSet(address indexed hooks);
    event RebateBpsSet(uint16 bps);
    event VaultRegistered(address indexed vault);
    event Distributed(address indexed vault, uint256 toTreasury, uint256 toStakers);

    error UnknownVault(address vault);

    constructor(address admin, address treasury_) GoldbenchAccess(admin) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function setHooks(IProjectTokenHooks h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = h;
        emit HooksSet(address(h));
    }

    function setRebateBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 0, MAX_REBATE_BPS);
        rebateBps = bps;
        emit RebateBpsSet(bps);
    }

    /// @dev Granted to the VaultFactory so vaults it creates are registered automatically.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    function registerVault(address vault) external onlyRole(REGISTRAR_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        isVault[vault] = true;
        emit VaultRegistered(vault);
    }

    // slither-disable-next-line incorrect-equality
    function distribute(address vault) external nonReentrant whenNotPaused {
        if (!isVault[vault]) revert UnknownVault(vault);
        uint256 bal = IERC20(vault).balanceOf(address(this));
        if (bal == 0) return;
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (address(h) != address(0) && h.projectToken() != address(0) && h.totalStaked() != 0) {
            toStakers = (bal * rebateBps) / 10_000;
        }
        uint256 toTreasury = bal - toStakers;
        emit Distributed(vault, toTreasury, toStakers);
        if (toStakers != 0) {
            IERC20(vault).safeTransfer(address(h), toStakers);
            h.notifyRebate(vault, toStakers);
        }
        if (toTreasury != 0) IERC20(vault).safeTransfer(treasury, toTreasury);
    }
}
