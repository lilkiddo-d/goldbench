// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";

/// @dev Test-only ERC-20. The project token ($GBEN) is NEVER deployed by this repo; tests use this mock.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Stock-token-like mock exposing the issuer's advisory `oraclePaused()` flag.
contract MockStockToken is MockERC20 {
    bool public oraclePaused;

    constructor(string memory n, string memory s) MockERC20(n, s, 18) {}

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

contract MockAggregator {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    uint8 public decimals;
    uint80 public latestRound;
    mapping(uint80 => Round) public rounds;
    int256 public startedAtOverride;

    constructor(uint8 d) {
        decimals = d;
    }

    function setPrice(int256 answer) external {
        _push(answer, block.timestamp);
    }

    function setPriceAt(int256 answer, uint256 ts) external {
        _push(answer, ts);
    }

    function _push(int256 answer, uint256 ts) internal {
        latestRound += 1;
        rounds[latestRound] = Round(answer, ts);
    }

    function setStartedAt(int256 s) external {
        startedAtOverride = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestRound];
        uint256 started = startedAtOverride != 0 ? uint256(startedAtOverride) : r.updatedAt;
        return (latestRound, r.answer, started, r.updatedAt, latestRound);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[id];
        require(r.updatedAt != 0, "no round");
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}

/// @dev Uniswap-SwapRouter02-shaped mock that fills at the aggregator price, minus fee and optional adverse skew.
contract MockSwapRouter is ISwapRouter02 {
    mapping(address => MockAggregator) public feedOf;
    mapping(address => uint8) public decOf;
    uint256 public feeBps = 5;
    uint256 public skewBps; // extra adverse price impact to simulate sandwiching / thin pools
    uint256 public bonusBps; // favourable fill vs oracle (pool cheaper than oracle)
    bool public shouldRevert;

    mapping(address => uint256) public bonusFor; // extra favourable fill per output token

    function setBonusFor(address tokenOut, uint256 bps) external {
        bonusFor[tokenOut] = bps;
    }

    function setBonus(uint256 bps) external {
        bonusBps = bps;
    }

    function setToken(address token, MockAggregator feed, uint8 dec) external {
        feedOf[token] = feed;
        decOf[token] = dec;
    }

    function setSkew(uint256 bps) external {
        skewBps = bps;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        (, int256 pin,,,) = feedOf[tokenIn].latestRoundData();
        (, int256 pout,,,) = feedOf[tokenOut].latestRoundData();
        uint256 usd = (amountIn * uint256(pin)) / (10 ** decOf[tokenIn]);
        uint256 out = (usd * (10 ** decOf[tokenOut])) / uint256(pout);
        return (out * (10_000 + bonusBps + bonusFor[tokenOut] - feeBps - skewBps)) / 10_000;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(!shouldRevert, "router: forced revert");
        out = quote(p.tokenIn, p.tokenOut, p.amountIn);
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

/// @dev Router that tries to re-enter the vault during a swap.
contract ReentrantRouter is ISwapRouter02 {
    address public target;
    bytes public payload;

    function arm(address t, bytes calldata d) external {
        target = t;
        payload = d;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256) {
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return 0;
    }
}
