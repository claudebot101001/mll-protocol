// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MutualLiquidityLock.sol";

contract MutualLiquidityLockTest is Test {
    MutualLiquidityLock public mll;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant DEPOSIT = 1 ether;
    uint256 constant INTERVAL = 30 days;
    uint256 constant BLEED_RATE = 50; // 0.5% per day in bps
    uint256 constant GRACE = 1; // 1 missed period grace
    uint256 constant DECAY_PERIODS = 6;

    // Track timestamp explicitly because via_ir optimizer caches block.timestamp
    uint256 internal ts = 1; // Foundry default

    function _warp(uint256 delta) internal {
        ts += delta;
        vm.warp(ts);
    }

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.prank(alice);
        mll = new MutualLiquidityLock(alice, bob, DEPOSIT, INTERVAL, BLEED_RATE, GRACE);
    }

    // ============================================================
    //                     ACTIVATION TESTS
    // ============================================================

    function test_ActivationRequiresBothParties() public {
        vm.prank(alice);
        mll.activate{value: DEPOSIT}();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Inactive));

        vm.prank(bob);
        mll.activate{value: DEPOSIT}();

        (, , , phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Active));
    }

    function test_ActivationRevertsForNonParty() public {
        address charlie = makeAddr("charlie");
        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        vm.expectRevert(MutualLiquidityLock.NotParty.selector);
        mll.activate{value: DEPOSIT}();
    }

    function test_InitialSharesCorrect() public {
        _activateBothParties();

        (uint256 shareA, uint256 shareB, uint256 total, ) = mll.getPoolState();
        assertEq(shareA, DEPOSIT);
        assertEq(shareB, DEPOSIT);
        assertEq(total, 2 * DEPOSIT);
    }

    // ============================================================
    //                     DEPOSIT TESTS
    // ============================================================

    function test_DepositIncreasesShare() public {
        _activateBothParties();

        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        (uint256 shareA, , , ) = mll.getPoolState();
        assertEq(shareA, 2 * DEPOSIT);
    }

    function test_DepositRevertsIfBelowMinimum() public {
        _activateBothParties();

        vm.prank(alice);
        vm.expectRevert("Below minimum deposit");
        mll.deposit{value: DEPOSIT / 2}();
    }

    function test_DepositRevertsIfAboveMax() public {
        _activateBothParties();

        vm.prank(alice);
        vm.expectRevert("Exceeds max deposit");
        mll.deposit{value: DEPOSIT * 4}();
    }

    // ============================================================
    //                     BLEEDING TESTS
    // ============================================================

    function test_NoBleedingWithinGracePeriod() public {
        _activateBothParties();

        _warp(INTERVAL);

        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        mll.applyBleeding();

        (, uint256 shareB, , ) = mll.getPoolState();
        assertEq(shareB, DEPOSIT);
    }

    function test_BleedingActivatesAfterGracePeriod() public {
        _activateBothParties();

        _warp(2 * INTERVAL);

        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        mll.applyBleeding();

        (uint256 shareA, uint256 shareB, , ) = mll.getPoolState();
        assertLt(shareB, DEPOSIT, "Bob's share should decrease");
        assertGt(shareA, 2 * DEPOSIT, "Alice should gain from bleeding");
        assertLt(shareA + shareB, 3 * DEPOSIT, "Some value burned");
    }

    function test_NoBleedingWhenBothDefault() public {
        _activateBothParties();

        _warp(2 * INTERVAL);

        mll.applyBleeding();

        (uint256 shareA, uint256 shareB, , ) = mll.getPoolState();
        assertEq(shareA, DEPOSIT, "No bleeding when both default");
        assertEq(shareB, DEPOSIT, "No bleeding when both default");
    }

    function test_BleedSplitIs70_30() public {
        _activateBothParties();

        // Warp past decay period so rate is steady
        _warpPastDecay();

        // Record state before bleeding
        (, uint256 bobBefore, , ) = mll.getPoolState();

        // Bob defaults for 2 intervals past grace
        _warp(2 * INTERVAL);
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        // Record alice's share before bleeding applied in this call
        (uint256 aliceBefore, , , ) = mll.getPoolState();

        mll.applyBleeding();

        (uint256 shareA, uint256 shareB, uint256 total, ) = mll.getPoolState();
        uint256 bobLost = bobBefore - shareB;
        uint256 aliceGained = shareA - aliceBefore;

        assertGt(bobLost, 0, "Bob lost share to bleeding");
        assertGt(aliceGained, 0, "Alice gained from bleeding");
        assertGt(aliceGained * 10000 / bobLost, 6500, "Alice gets ~70%");
        assertLt(aliceGained * 10000 / bobLost, 7500, "Alice gets ~70%");
        assertGt(address(mll).balance, total, "Contract holds burned tokens");
    }

    function test_DecayingBleedRateHigherInitially() public {
        _activateBothParties();

        uint256 initialRate = mll.getEffectiveBleedRate();
        assertGt(initialRate, BLEED_RATE, "Initial rate should be > steady state");
        assertLe(initialRate, BLEED_RATE * 2, "Initial rate should be <= 2x steady state");

        _warp(DECAY_PERIODS * INTERVAL);
        uint256 steadyRate = mll.getEffectiveBleedRate();
        assertEq(steadyRate, BLEED_RATE, "Should reach steady state after decay period");
    }

    // ============================================================
    //                     PEACEFUL EXIT TESTS
    // ============================================================

    function test_PeacefulExitRequiresBothProposals() public {
        _activateBothParties();

        vm.prank(alice);
        mll.proposeExit();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Active));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mll.proposeExit();

        (, , , phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Exited));

        // Pull-based: funds are claimable, not auto-sent
        assertEq(mll.claimable(alice), DEPOSIT);
        assertEq(mll.claimable(bob), DEPOSIT);

        // Withdraw
        vm.prank(alice);
        mll.withdraw();
        vm.prank(bob);
        mll.withdraw();

        assertEq(alice.balance, aliceBefore + DEPOSIT);
        assertEq(bob.balance, bobBefore + DEPOSIT);
    }

    function test_ExitProposalCanBeCancelled() public {
        _activateBothParties();

        vm.prank(alice);
        mll.proposeExit();

        vm.prank(alice);
        mll.cancelExitProposal();

        vm.prank(bob);
        mll.proposeExit();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Active));
    }

    // ============================================================
    //                  UNILATERAL EXIT TESTS
    // ============================================================

    function test_UnilateralExitInitiatesCountdown() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        (address initiator, uint256 executeAfter, bool active) = mll.pendingExit();
        assertEq(initiator, alice);
        assertEq(executeAfter, ts + 30 days);
        assertTrue(active);
    }

    function test_UnilateralExitRevertsBeforeCountdown() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        vm.prank(alice);
        vm.expectRevert();
        mll.executeUnilateralExit();
    }

    function test_UnilateralExitExecutesWithPenalty() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        _warp(30 days + 1);

        vm.prank(bob);
        mll.deposit{value: DEPOSIT}();

        vm.prank(alice);
        mll.executeUnilateralExit();

        // Pull-based: check claimable
        uint256 aliceClaimable = mll.claimable(alice);
        uint256 bobClaimable = mll.claimable(bob);

        assertLt(aliceClaimable, DEPOSIT, "Alice receives less than deposit due to penalty");
        assertGt(bobClaimable, 2 * DEPOSIT, "Bob receives his deposit plus Alice's penalty");

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Exited));
    }

    function test_UnilateralExitCanBeCancelled() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        vm.prank(alice);
        mll.cancelUnilateralExit();

        (, , bool active) = mll.pendingExit();
        assertFalse(active);
    }

    function test_OnlyInitiatorCanCancelUnilateralExit() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        vm.prank(bob);
        vm.expectRevert("Only initiator can cancel");
        mll.cancelUnilateralExit();
    }

    function test_CannotInitiateTwoUnilateralExits() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        vm.prank(bob);
        vm.expectRevert(MutualLiquidityLock.UnilateralExitAlreadyActive.selector);
        mll.initiateUnilateralExit();
    }

    // ============================================================
    //                  DEAD MAN'S SWITCH TESTS
    // ============================================================

    function test_ClaimAbandonedAfter90Days() public {
        _activateBothParties();

        _warp(91 days);

        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        vm.prank(alice);
        mll.claimAbandoned();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Exited));

        uint256 aliceClaimable = mll.claimable(alice);
        assertGt(aliceClaimable, 0, "Alice can claim pool");
    }

    function test_ClaimAbandonedRevertsIfCounterpartyActive() public {
        _activateBothParties();

        _warp(30 days);
        vm.prank(bob);
        mll.deposit{value: DEPOSIT}();

        vm.prank(alice);
        vm.expectRevert("Counterparty still active");
        mll.claimAbandoned();
    }

    function test_ClaimAbandonedRequiresClaimerMoreActive() public {
        _activateBothParties();

        // Both stop depositing for 91 days
        _warp(91 days);

        // Alice tries to claim without depositing — should fail
        vm.prank(alice);
        vm.expectRevert("Claimer must be more active than counterparty");
        mll.claimAbandoned();
    }

    // ============================================================
    //                  INACTIVE CANCELLATION TESTS
    // ============================================================

    function test_CancelInactiveAfterTimeout() public {
        vm.prank(alice);
        mll.activate{value: DEPOSIT}();

        // Bob never activates. Wait 7 days.
        _warp(7 days + 1);

        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        mll.cancelInactive();

        assertEq(mll.claimable(alice), DEPOSIT);

        vm.prank(alice);
        mll.withdraw();

        assertEq(alice.balance, aliceBefore + DEPOSIT);
    }

    function test_CancelInactiveRevertsBeforeTimeout() public {
        vm.prank(alice);
        mll.activate{value: DEPOSIT}();

        vm.prank(alice);
        vm.expectRevert("Too early to cancel");
        mll.cancelInactive();
    }

    // ============================================================
    //                  RUSSIAN ROULETTE TESTS
    // ============================================================

    function test_RRBlockedDuringWarmup() public {
        _activateBothParties();

        vm.prank(alice);
        vm.expectRevert();
        mll.invokeRoulette{value: DEPOSIT}();
    }

    function test_RRCanBeInvoked() public {
        _activateBothParties();
        _warpPastWarmup();

        vm.prank(alice);
        mll.invokeRoulette{value: DEPOSIT}();

        (uint256 invCount, , , ) = mll.getRRState();
        assertEq(invCount, 1);
    }

    function test_RRRequiresDeposit() public {
        _activateBothParties();
        _warpPastWarmup();

        vm.prank(alice);
        vm.expectRevert("Must deposit to invoke RR");
        mll.invokeRoulette();
    }

    function test_RRShareGateBlocksLowStakeInvoker() public {
        _activateBothParties();
        _warpPastWarmup();

        // Make Bob's share very large relative to Alice
        for (uint i = 0; i < 3; i++) {
            vm.prank(bob);
            mll.deposit{value: DEPOSIT * 3}();
        }

        // Alice has much less than 35% of pool — should be blocked
        vm.prank(alice);
        vm.expectRevert();
        mll.invokeRoulette{value: DEPOSIT}();
    }

    function test_RRCooldownPreventsImmediate() public {
        _activateBothParties();
        _warpPastWarmup();

        vm.prank(alice);
        mll.invokeRoulette{value: DEPOSIT}();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        if (phase == MutualLiquidityLock.Phase.Active) {
            vm.prank(bob);
            vm.expectRevert();
            mll.invokeRoulette{value: DEPOSIT}();
        }
    }

    function test_RRCooldownExpiresAfter10Days() public {
        _activateBothParties();
        _warpPastWarmup();

        vm.prank(alice);
        mll.invokeRoulette{value: DEPOSIT}();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        if (phase == MutualLiquidityLock.Phase.Active) {
            _warp(10 days + 1);

            vm.prank(bob);
            mll.invokeRoulette{value: DEPOSIT}();

            (uint256 invCount, , , ) = mll.getRRState();
            assertEq(invCount, 2);
        }
    }

    function test_RRCertainTriggerAtSixthInvocation() public {
        _activateBothParties();
        _warpPastWarmup();

        for (uint i = 0; i < 6; i++) {
            (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
            if (phase != MutualLiquidityLock.Phase.Active) break;

            _warp(10 days + 1);
            vm.prank(i % 2 == 0 ? alice : bob);
            mll.invokeRoulette{value: DEPOSIT}();
        }

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Frozen));
    }

    function test_RRNonPartyCannotInvoke() public {
        _activateBothParties();
        _warpPastWarmup();

        address charlie = makeAddr("charlie");
        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        vm.expectRevert(MutualLiquidityLock.NotParty.selector);
        mll.invokeRoulette{value: DEPOSIT}();
    }

    // ============================================================
    //                  FREEZE DURATION TESTS
    // ============================================================

    function test_FrozenFundsCanBeReleasedAfterDuration() public {
        _activateBothParties();
        _warpPastWarmup();

        _forceFreeze();

        (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Frozen));

        // Cannot release before duration expires
        vm.prank(alice);
        vm.expectRevert();
        mll.releaseFrozenFunds();

        // Warp to after freeze duration (10 years)
        _warp(3650 days + 1);

        vm.prank(alice);
        mll.releaseFrozenFunds();

        (, , , phase) = mll.getPoolState();
        assertEq(uint256(phase), uint256(MutualLiquidityLock.Phase.Exited));

        assertGt(mll.claimable(alice), 0, "Alice has claimable funds");
        assertGt(mll.claimable(bob), 0, "Bob has claimable funds");
    }

    // ============================================================
    //                     WITHDRAWAL TESTS
    // ============================================================

    function test_WithdrawAfterPeacefulExit() public {
        _activateBothParties();

        vm.prank(alice);
        mll.proposeExit();
        vm.prank(bob);
        mll.proposeExit();

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mll.withdraw();
        assertEq(alice.balance, aliceBefore + DEPOSIT);

        // Double withdraw should revert
        vm.prank(alice);
        vm.expectRevert(MutualLiquidityLock.NothingToWithdraw.selector);
        mll.withdraw();
    }

    // ============================================================
    //                     INVARIANT TESTS
    // ============================================================

    function test_PoolBalanceAlwaysGteShares() public {
        _activateBothParties();

        for (uint i = 0; i < 5; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();

            if (i % 2 == 0) {
                vm.prank(bob);
                mll.deposit{value: DEPOSIT}();
            }

            mll.applyBleeding();

            (uint256 shareA, uint256 shareB, uint256 total, ) = mll.getPoolState();
            assertEq(total, shareA + shareB, "Total = shareA + shareB");
            assertGe(address(mll).balance, total, "Contract balance >= total shares");
        }
    }

    // ============================================================
    //                     HELPERS
    // ============================================================

    function _activateBothParties() internal {
        vm.prank(alice);
        mll.activate{value: DEPOSIT}();

        vm.prank(bob);
        mll.activate{value: DEPOSIT}();
    }

    function _warpPastWarmup() internal {
        for (uint i = 0; i < 4; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }
    }

    function _warpPastDecay() internal {
        _warpPastWarmup();
        for (uint i = 0; i < DECAY_PERIODS; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }
    }

    function _forceFreeze() internal {
        for (uint i = 0; i < 6; i++) {
            (, , , MutualLiquidityLock.Phase phase) = mll.getPoolState();
            if (phase != MutualLiquidityLock.Phase.Active) break;
            _warp(10 days + 1);
            vm.prank(i % 2 == 0 ? alice : bob);
            mll.invokeRoulette{value: DEPOSIT}();
        }
    }
}
