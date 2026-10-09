// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {GoldbenchAccess} from "../../src/access/GoldbenchAccess.sol";
import {MockAggregator, MockStockToken, MockERC20} from "../mocks/Mocks.sol";

contract OracleAdapterTest is Test {
    ChainlinkOracleAdapter oracle;
    MockAggregator feed;
    MockStockToken token;
    address admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new ChainlinkOracleAdapter(admin);
        feed = new MockAggregator(8);
        token = new MockStockToken("SPY", "SPY");
        feed.setPrice(500e8);
        vm.prank(admin);
        oracle.setFeed(address(token), address(feed), 1 days, true);
    }

    function test_scalesTo18() public view {
        (uint256 p, uint256 ts) = oracle.getPrice(address(token));
        assertEq(p, 500e18);
        assertEq(ts, block.timestamp);
        assertTrue(oracle.isSupported(address(token)));
        assertFalse(oracle.isSupported(address(1)));
    }

    function test_scaleOtherDecimals() public {
        MockAggregator f18 = new MockAggregator(18);
        MockAggregator f20 = new MockAggregator(20);
        f18.setPrice(2e18);
        f20.setPrice(3e20);
        vm.startPrank(admin);
        oracle.setFeed(address(10), address(f18), 1 days, false);
        oracle.setFeed(address(11), address(f20), 1 days, false);
        vm.stopPrank();
        (uint256 a,) = oracle.getPrice(address(10));
        (uint256 b,) = oracle.getPrice(address(11));
        assertEq(a, 2e18);
        assertEq(b, 3e18);
    }

    function test_revertsStale() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.StalePrice.selector, address(token), 1_800_000_000));
        oracle.getPrice(address(token));
    }

    function test_revertsFutureTimestamp() public {
        feed.setPriceAt(1e8, block.timestamp + 10);
        vm.expectRevert();
        oracle.getPrice(address(token));
    }

    function test_revertsNonPositive() public {
        feed.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.InvalidPrice.selector, address(token), int256(0)));
        oracle.getPrice(address(token));
        feed.setPrice(-1);
        vm.expectRevert();
        oracle.getPrice(address(token));
    }

    function test_revertsWhenIssuerPausedOracle() public {
        token.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.OraclePausedByIssuer.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_toleratesTokenWithoutPauseFlag() public {
        MockERC20 plain = new MockERC20("X", "X", 18);
        vm.prank(admin);
        oracle.setFeed(address(plain), address(feed), 1 days, true);
        (uint256 p,) = oracle.getPrice(address(plain));
        assertEq(p, 500e18);
    }

    function test_unsupported() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.UnsupportedAsset.selector, address(1)));
        oracle.getPrice(address(1));
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0);
        seq.setPrice(0); // up
        seq.setStartedAt(int256(block.timestamp - 2 hours));
        vm.prank(admin);
        oracle.setSequencerFeed(address(seq), 1 hours);
        oracle.getPrice(address(token));

        seq.setStartedAt(int256(block.timestamp - 10 minutes));
        vm.expectRevert(ChainlinkOracleAdapter.SequencerGracePeriod.selector);
        oracle.getPrice(address(token));

        seq.setPrice(1); // down
        vm.expectRevert(ChainlinkOracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(token));
    }

    function test_roundPrice() public {
        feed.setPriceAt(400e8, block.timestamp - 3 days);
        (uint256 p, uint256 ts) = oracle.getRoundPrice(address(token), 2);
        assertEq(p, 400e18);
        assertEq(ts, block.timestamp - 3 days);
        vm.expectRevert();
        oracle.getRoundPrice(address(token), 99);
    }

    function test_setFeedBoundsAndAccess() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(GoldbenchAccess.OutOfBounds.selector, 10, 1 hours, 4 days));
        oracle.setFeed(address(token), address(feed), 10, true);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        oracle.setFeed(address(0), address(feed), 1 days, true);
        vm.expectRevert();
        oracle.setSequencerFeed(address(feed), 2 days);
        vm.stopPrank();
        vm.expectRevert();
        oracle.setFeed(address(token), address(feed), 1 days, true);
    }
}
