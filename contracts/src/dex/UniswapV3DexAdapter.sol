// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IDexAdapter} from "../interfaces/IGoldbench.sol";
import {ISwapRouter02} from "../interfaces/IExternal.sol";

/// @title UniswapV3DexAdapter
/// @notice Single-hop exact-input swaps between the base stablecoin and a configured asset through Uniswap v3
///         SwapRouter02. Enforces a caller-supplied deadline (SwapRouter02 has none) and min-out (checked again on the
///         recipient's balance delta). Holds no funds between calls. Swappable behind IDexAdapter (e.g. for an RFQ
///         venue such as Rialto) by the Timelock.
contract UniswapV3DexAdapter is GoldbenchAccess, ReentrancyGuard, IDexAdapter {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    address public immutable baseToken;

    mapping(address asset => uint24 fee) public poolFee; // fee tier of the asset/base pool, 0 = unsupported

    event PoolFeeSet(address indexed asset, uint24 fee);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error Expired();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error InvalidFee(uint24 fee);
    error ZeroAmount();

    constructor(address admin, ISwapRouter02 router_, address baseToken_) GoldbenchAccess(admin) {
        if (address(router_) == address(0) || baseToken_ == address(0)) revert ZeroAddress();
        router = router_;
        baseToken = baseToken_;
    }

    function setPoolFee(address asset, uint24 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (fee != 0 && fee != 100 && fee != 500 && fee != 3000 && fee != 10_000) revert InvalidFee(fee);
        poolFee[asset] = fee;
        emit PoolFeeSet(asset, fee);
    }

    /// @inheritdoc IDexAdapter
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        address asset = tokenIn == baseToken ? tokenOut : tokenIn;
        uint24 fee = poolFee[asset];
        if (fee == 0 || (tokenIn != baseToken && tokenOut != baseToken) || tokenIn == tokenOut) {
            revert UnsupportedPair(tokenIn, tokenOut);
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        IERC20(tokenIn).forceApprove(address(router), 0);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
