// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {UniswapV3DexAdapter} from "../../src/dex/UniswapV3DexAdapter.sol";
import {ProjectTokenHooks} from "../../src/token/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/fees/FeeCollector.sol";
import {Timelock} from "../../src/governance/Timelock.sol";
import {ComplianceRegistry} from "../../src/compliance/ComplianceRegistry.sol";
import {VaultFactory, IRegistrar, IHooksRegistrar} from "../../src/vault/VaultFactory.sol";
import {GoldbenchAccess} from "../../src/access/GoldbenchAccess.sol";
import {ISignalEngine, IProjectTokenHooks} from "../../src/interfaces/IGoldbench.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";
import {SignalEngine} from "../../src/signal/SignalEngine.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract DexAdapterTest is Fixture {
    function _fund(uint256 amt) internal {
        usdg.mint(address(this), amt);
        usdg.approve(address(dex), amt);
    }

    function test_swapBothDirections() public {
        _fund(1000e6);
        uint256 out = dex.swapExactIn(address(usdg), address(spy), 1000e6, 1.99e18, address(this), block.timestamp);
        assertApproxEqRel(out, 2e18, 0.001e18);
        assertEq(usdg.allowance(address(dex), address(router)), 0);
        spy.approve(address(dex), out);
        uint256 back = dex.swapExactIn(address(spy), address(usdg), out, 990e6, address(this), block.timestamp);
        assertGt(back, 990e6);
    }

    function test_guards() public {
        _fund(10e6);
        vm.expectRevert(UniswapV3DexAdapter.Expired.selector);
        dex.swapExactIn(address(usdg), address(spy), 1e6, 0, address(this), block.timestamp - 1);
        vm.expectRevert(UniswapV3DexAdapter.ZeroAmount.selector);
        dex.swapExactIn(address(usdg), address(spy), 0, 0, address(this), block.timestamp);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        dex.swapExactIn(address(usdg), address(spy), 1e6, 0, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3DexAdapter.UnsupportedPair.selector, address(spy), address(qqq)));
        dex.swapExactIn(address(spy), address(qqq), 1e6, 0, address(this), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3DexAdapter.UnsupportedPair.selector, address(usdg), address(7)));
        dex.swapExactIn(address(usdg), address(7), 1e6, 0, address(this), block.timestamp);
        vm.expectRevert("Too little received");
        dex.swapExactIn(address(usdg), address(spy), 10e6, 1e18, address(this), block.timestamp);
    }

    function test_adminAndPause() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3DexAdapter.InvalidFee.selector, 42));
        dex.setPoolFee(address(spy), 42);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        dex.setPoolFee(address(0), 500);
        dex.setPoolFee(address(spy), 0);
        dex.grantRole(dex.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
        vm.prank(guardian);
        dex.pause();
        _fund(1e6);
        vm.expectRevert();
        dex.swapExactIn(address(usdg), address(qqq), 1e6, 0, address(this), block.timestamp);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new UniswapV3DexAdapter(admin, ISwapRouter02(address(0)), address(usdg));
    }
}

contract GovernanceTest is Fixture {
    MockERC20 gben; // test-only mock of the externally launched project token

    function setUp() public override {
        super.setUp();
        gben = new MockERC20("Mock GBEN", "mGBEN", 18);
        gben.mint(alice, 1000e18);
        gben.mint(bob, 1000e18);
        vm.prank(alice);
        gben.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        gben.approve(address(hooks), type(uint256).max);
    }

    function _setToken() internal {
        vm.prank(admin);
        hooks.setProjectToken(address(gben));
    }

    function test_tokenFeaturesDisabledUntilSet() public {
        vm.startPrank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.unstake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.propose(3, 1000);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.vote(1, true);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.queue(1);
        vm.stopPrank();
    }

    function test_setProjectTokenOnceByAdmin() public {
        vm.expectRevert();
        hooks.setProjectToken(address(gben));
        vm.startPrank(admin);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        hooks.setProjectToken(address(0));
        hooks.setProjectToken(address(gben));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(1));
        vm.stopPrank();
        assertEq(hooks.projectToken(), address(gben));
    }

    function test_stakeUnstake() public {
        _setToken();
        vm.startPrank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        hooks.stake(100e18);
        assertEq(hooks.totalStaked(), 100e18);
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.unstake(101e18);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.unstake(0);
        hooks.unstake(40e18);
        vm.stopPrank();
        assertEq(gben.balanceOf(alice), 940e18);
    }

    function test_feeRebateFlow() public {
        _setToken();
        vm.prank(alice);
        hooks.stake(300e18);
        vm.prank(bob);
        hooks.stake(100e18);

        _deposit(steady, makeAddr("lp"), 1_000_000e6);
        vm.warp(block.timestamp + 365 days);
        steady.accrueFees();
        uint256 feeShares = steady.balanceOf(address(fees));
        fees.distribute(address(steady));
        uint256 toStakers = feeShares / 2;
        assertApproxEqAbs(steady.balanceOf(treasury), feeShares - toStakers, 1);
        assertApproxEqAbs(hooks.claimable(address(steady), alice), (toStakers * 3) / 4, 2);
        assertApproxEqAbs(hooks.claimable(address(steady), bob), toStakers / 4, 2);

        vm.prank(alice);
        uint256 got = hooks.claimRebate(address(steady));
        assertApproxEqAbs(got, (toStakers * 3) / 4, 2);
        assertEq(steady.balanceOf(alice), got);
        vm.prank(alice);
        assertEq(hooks.claimRebate(address(steady)), 0);
        vm.expectRevert(abi.encodeWithSelector(ProjectTokenHooks.UnknownVault.selector, address(1)));
        hooks.claimRebate(address(1));

        // late staker earns nothing from past rebates
        address carol = makeAddr("carol");
        gben.mint(carol, 10e18);
        vm.startPrank(carol);
        gben.approve(address(hooks), 10e18);
        hooks.stake(10e18);
        vm.stopPrank();
        assertEq(hooks.claimable(address(steady), carol), 0);
    }

    function test_feeCollectorConfig() public {
        vm.startPrank(admin);
        fees.setRebateBps(10_000);
        vm.expectRevert();
        fees.setRebateBps(10_001);
        fees.setTreasury(bob);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        fees.setTreasury(address(0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(FeeCollector.UnknownVault.selector, address(1)));
        fees.distribute(address(1));
        fees.distribute(address(steady)); // empty → no-op
        vm.expectRevert(ProjectTokenHooks.NotFeeCollector.selector);
        hooks.notifyRebate(address(steady), 1);
        vm.prank(address(fees));
        vm.expectRevert(abi.encodeWithSelector(ProjectTokenHooks.UnknownVault.selector, address(1)));
        hooks.notifyRebate(address(1), 1);
        vm.prank(address(fees));
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        hooks.notifyRebate(address(steady), 1);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new FeeCollector(admin, address(0));
    }

    function _wireGovernance() internal {
        // hand SignalEngine admin to the timelock and let hooks propose (as Deploy.s.sol + TOKEN_INTEGRATION.md do)
        bytes32 adminRole = engine.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        engine.grantRole(adminRole, address(timelock));
        bytes memory data = abi.encodeCall(AccessControl.grantRole, (timelock.PROPOSER_ROLE(), address(hooks)));
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));
    }

    function test_stakerVoteExecutesThroughTimelock() public {
        _setToken();
        _wireGovernance();
        vm.prank(alice);
        hooks.stake(600e18);
        vm.prank(bob);
        hooks.stake(400e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GoldbenchAccess.OutOfBounds.selector, 9000, 500, 4000));
        hooks.propose(3, 9000); // outside hard bounds → rejected at proposal time

        vm.prank(bob);
        uint256 id = hooks.propose(3, 2000); // target vol 15 % → 20 %
        vm.prank(alice);
        hooks.vote(id, true);
        vm.prank(bob);
        hooks.vote(id, false);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.AlreadyVoted.selector);
        hooks.vote(id, true);

        // voters cannot unstake (and re-vote elsewhere) until the vote ends
        vm.prank(alice);
        vm.expectPartialRevert(ProjectTokenHooks.StakeLocked.selector);
        hooks.unstake(1e18);

        vm.expectRevert(ProjectTokenHooks.VotingOpen.selector);
        hooks.queue(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.VotingClosed.selector);
        hooks.vote(id, true);

        bytes32 op = hooks.queue(id);
        vm.expectRevert(ProjectTokenHooks.AlreadyQueued.selector);
        hooks.queue(id);
        assertTrue(timelock.isOperationPending(op));

        bytes memory data = abi.encodeCall(ISignalEngine.setParam, (uint8(3), uint256(2000)));
        bytes32 salt = keccak256(abi.encode(address(hooks), id));
        vm.expectRevert();
        timelock.execute(address(engine), 0, data, bytes32(0), salt);
        vm.warp(block.timestamp + 48 hours);
        timelock.execute(address(engine), 0, data, bytes32(0), salt);
        assertEq(engine.param(3), 2000);

        vm.prank(alice);
        hooks.unstake(600e18);
    }

    function test_failedVotesAndQuorum() public {
        _setToken();
        _wireGovernance();
        vm.prank(alice);
        hooks.stake(1000e18);
        vm.prank(bob);
        hooks.stake(1e18);

        vm.prank(bob);
        uint256 id = hooks.propose(5, 200);
        vm.prank(bob);
        hooks.vote(id, true); // 1e18 for, quorum = 10 % of 1001e18
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(ProjectTokenHooks.ProposalFailed.selector);
        hooks.queue(id);
        vm.expectRevert(ProjectTokenHooks.ProposalFailed.selector);
        hooks.queue(999);
        vm.expectRevert(ProjectTokenHooks.VotingClosed.selector);
        hooks.vote(999, true);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(ProjectTokenHooks.BelowThreshold.selector);
        hooks.propose(5, 200);

        vm.prank(alice);
        id = hooks.propose(5, 200);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.vote(id, true);
    }

    function test_governanceParams() public {
        vm.startPrank(admin);
        hooks.setGovernanceParams(5e18, 2 days, 2000);
        assertEq(hooks.votingPeriod(), 2 days);
        vm.expectRevert();
        hooks.setGovernanceParams(5e18, 1 hours, 2000);
        vm.expectRevert();
        hooks.setGovernanceParams(5e18, 2 days, 9000);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.setGovernanceParams(0, 2 days, 2000);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        hooks.setFeeCollector(address(0));
        vm.stopPrank();
        assertEq(hooks.vaults().length, 3);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new ProjectTokenHooks(admin, ISignalEngine(address(0)), timelock);
    }

    function test_addVaultLimits() public {
        bytes32 role = hooks.REGISTRAR_ROLE();
        vm.prank(admin);
        hooks.grantRole(role, admin);
        vm.startPrank(admin);
        hooks.addVault(address(steady)); // idempotent
        for (uint160 i = 1; i <= 5; ++i) hooks.addVault(address(i));
        vm.expectRevert(ProjectTokenHooks.TooManyVaults.selector);
        hooks.addVault(address(99));
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        hooks.addVault(address(0));
        vm.stopPrank();
    }
}

contract TimelockAndFactoryTest is Fixture {
    function deployTimelock(uint256 d) external returns (Timelock) {
        address[] memory p = new address[](0);
        return new Timelock(d, p, p, address(0));
    }

    function test_timelockFloor() public {
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayBelowFloor.selector, 1 hours));
        this.deployTimelock(1 hours);
        assertEq(timelock.getMinDelay(), 48 hours);
        vm.expectRevert();
        timelock.updateDelay(72 hours);

        bytes memory low = abi.encodeCall(TimelockController.updateDelay, (1 hours));
        bytes memory high = abi.encodeCall(TimelockController.updateDelay, (72 hours));
        vm.startPrank(admin);
        timelock.schedule(address(timelock), 0, low, bytes32(0), bytes32(0), 48 hours);
        timelock.schedule(address(timelock), 0, high, bytes32(0), bytes32(uint256(1)), 48 hours);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert();
        timelock.execute(address(timelock), 0, low, bytes32(0), bytes32(0));
        timelock.execute(address(timelock), 0, high, bytes32(0), bytes32(uint256(1)));
        assertEq(timelock.getMinDelay(), 72 hours);
    }

    function test_factory() public {
        assertEq(factory.vaultCount(), 3);
        assertEq(factory.vaults()[2], address(bold));
        assertTrue(engine.hasRole(engine.VAULT_ROLE(), address(bold)));
        assertTrue(fees.isVault(address(bold)));
        assertTrue(hooks.isVault(address(bold)));
        vm.expectRevert();
        factory.createVault(_params("x", "x", 100));
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(admin, address(0), engine, IRegistrar(address(fees)), IHooksRegistrar(address(hooks)));
    }

    function test_compliance() public {
        address[] memory list = new address[](201);
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        compliance.setAllowed(list, bytes32(0), true);
        vm.prank(admin);
        compliance.setEnabled(true);
        bytes32 dep = keccak256("DEPOSIT");
        assertFalse(compliance.isAllowed(bob, dep));
        address[] memory one = new address[](1);
        one[0] = bob;
        vm.prank(admin);
        compliance.setAllowed(one, dep, true);
        assertTrue(compliance.isAllowed(bob, dep));
        assertFalse(compliance.isAllowed(bob, keccak256("TRANSFER")));
        vm.expectRevert();
        compliance.setEnabled(false);
    }
}
