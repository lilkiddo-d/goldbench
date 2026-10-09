// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PriceHistory} from "../src/signal/PriceHistory.sol";
import {RotationVault} from "../src/vault/RotationVault.sol";
import {FeeCollector} from "../src/fees/FeeCollector.sol";

/// @title Keeper actions
/// @notice Thin, keystore-signed entry points used by scripts/src/keeper.ts. Each action re-checks its own
///         preconditions on-chain, so a mistimed call simply reverts in simulation and is never broadcast.
///   forge script script/Keeper.s.sol --sig "record()"        --rpc-url $RPC --account goldbench-keeper --broadcast
///   forge script script/Keeper.s.sol --sig "start(address)"  <vault> ...
///   forge script script/Keeper.s.sol --sig "chunk(address)"  <vault> ...
contract Keeper is Script {
    function _deployment() internal view returns (string memory json) {
        string memory path = vm.envOr(
            "GOLDBENCH_DEPLOYMENT",
            string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json")
        );
        json = vm.readFile(path);
    }

    function record() external {
        PriceHistory h = PriceHistory(vm.parseJsonAddress(_deployment(), ".priceHistory"));
        vm.startBroadcast();
        uint256 day = h.recordDailyCloses();
        vm.stopBroadcast();
        console2.log("recorded session day", day);
    }

    function start(address vault) external {
        vm.startBroadcast();
        RotationVault(vault).startRebalance();
        vm.stopBroadcast();
        console2.log("rebalance started", RotationVault(vault).rebalanceId());
    }

    function chunk(address vault) external {
        uint256 deadline = block.timestamp + vm.envOr("GOLDBENCH_SWAP_DEADLINE", uint256(5 minutes));
        vm.startBroadcast();
        RotationVault(vault).executeChunk(deadline);
        vm.stopBroadcast();
        (, uint8 done, uint8 total,,) = RotationVault(vault).plan();
        console2.log("chunk", done, "of", total);
    }

    function distribute(address vault) external {
        FeeCollector f = FeeCollector(vm.parseJsonAddress(_deployment(), ".feeCollector"));
        vm.startBroadcast();
        f.distribute(vault);
        vm.stopBroadcast();
    }
}
