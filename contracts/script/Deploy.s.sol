// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MutualLiquidityLock.sol";

/// @notice Deployment script for MLL Protocol
/// @dev Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
///
///   The deployer becomes partyA. Set PARTY_B env var to the counterparty address.
///   Set TESTNET=true for short intervals.
contract DeployMLL is Script {
    function run() external {
        address partyB = vm.envAddress("PARTY_B");
        bool isTestnet = vm.envOr("TESTNET", true);

        uint256 depositAmount;
        uint256 depositInterval;
        uint256 bleedRate;
        uint256 gracePeriods;
        uint256 exitPenaltyMax;
        uint256 exitPenaltyMin;
        uint256 penaltyDecayTarget;

        if (isTestnet) {
            depositAmount = 0.01 ether;
            depositInterval = 5 minutes;
            bleedRate = 100;     // 1%/day
            gracePeriods = 1;
            exitPenaltyMax = 8000;  // 80%
            exitPenaltyMin = 1500;  // 15%
            penaltyDecayTarget = 7; // 7 deposits to reach min
        } else {
            depositAmount = 0.1 ether;
            depositInterval = 30 days;
            bleedRate = 50;      // 0.5%/day
            gracePeriods = 1;
            exitPenaltyMax = 8000;
            exitPenaltyMin = 1500;
            penaltyDecayTarget = 7;
        }

        vm.startBroadcast();

        MutualLiquidityLock mll = new MutualLiquidityLock(
            msg.sender,
            partyB,
            depositAmount,
            depositInterval,
            bleedRate,
            gracePeriods,
            exitPenaltyMax,
            exitPenaltyMin,
            penaltyDecayTarget
        );

        console.log("MLL deployed at:", address(mll));
        console.log("Party A:", msg.sender);
        console.log("Party B:", partyB);
        console.log("Deposit amount:", depositAmount);
        console.log("Deposit interval:", depositInterval);
        console.log("Bleed rate (bps/day):", bleedRate);
        console.log("Exit penalty max (bps):", exitPenaltyMax);
        console.log("Exit penalty min (bps):", exitPenaltyMin);
        console.log("Penalty decay target:", penaltyDecayTarget);
        console.log("Testnet mode:", isTestnet);

        vm.stopBroadcast();
    }
}
