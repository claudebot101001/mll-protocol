// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MutualLiquidityLock.sol";

/// @notice Deployment script for MLL Protocol
/// @dev Usage:
///   Testnet (short intervals for demo):
///     forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
///
///   The deployer becomes partyA. Set PARTY_B env var to the counterparty address.
///   Set TESTNET=true for short intervals (5 min deposit, 1 day freeze).
contract DeployMLL is Script {
    function run() external {
        address partyB = vm.envAddress("PARTY_B");
        bool isTestnet = vm.envOr("TESTNET", true);

        uint256 depositAmount;
        uint256 depositInterval;
        uint256 bleedRate;
        uint256 gracePeriods;

        if (isTestnet) {
            // Testnet: 5-minute intervals, 0.01 ETH deposits, aggressive bleed for fast demo
            depositAmount = 0.01 ether;
            depositInterval = 5 minutes;
            bleedRate = 100;     // 1%/day — 2x at launch = 2%/day, visible in minutes
            gracePeriods = 1;
        } else {
            // Production: 30-day intervals, 0.1 ETH deposits
            depositAmount = 0.1 ether;
            depositInterval = 30 days;
            bleedRate = 50;      // 0.5%/day steady state
            gracePeriods = 1;
        }

        vm.startBroadcast();

        MutualLiquidityLock mll = new MutualLiquidityLock(
            msg.sender,
            partyB,
            depositAmount,
            depositInterval,
            bleedRate,
            gracePeriods
        );

        console.log("MLL deployed at:", address(mll));
        console.log("Party A:", msg.sender);
        console.log("Party B:", partyB);
        console.log("Deposit amount:", depositAmount);
        console.log("Deposit interval:", depositInterval);
        console.log("Bleed rate (bps/day):", bleedRate);
        console.log("Testnet mode:", isTestnet);

        vm.stopBroadcast();
    }
}
