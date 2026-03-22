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
    uint256 constant EXIT_PENALTY_MAX = 8000; // 80%
    uint256 constant EXIT_PENALTY_MIN = 1500; // 15%
    uint256 constant PENALTY_DECAY_TARGET = 7; // 7 deposits to reach min penalty

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
        mll = new MutualLiquidityLock(
            alice, bob, DEPOSIT, INTERVAL, BLEED_RATE, GRACE,
            EXIT_PENALTY_MAX, EXIT_PENALTY_MIN, PENALTY_DECAY_TARGET
        );
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

        // Mutual default period — both miss deposits
        _warp(2 * INTERVAL);
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        // Warp INTERVAL (not 2x) so Alice has periodsMissed=1 (<=grace), still compliant
        // Bob continues defaulting → his bleed window opens from Alice's resume point
        _warp(INTERVAL);
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        (uint256 shareA, uint256 shareB, , ) = mll.getPoolState();
        assertLt(shareB, DEPOSIT, "Bob's share should decrease");
        assertGt(shareA, 3 * DEPOSIT, "Alice should gain from bleeding");
        // 100% transfer: total pool value preserved
        assertEq(shareA + shareB, 4 * DEPOSIT, "No value burned, total preserved");
    }

    function test_NoBleedingWhenBothDefault() public {
        _activateBothParties();

        _warp(2 * INTERVAL);

        mll.applyBleeding();

        (uint256 shareA, uint256 shareB, , ) = mll.getPoolState();
        assertEq(shareA, DEPOSIT, "No bleeding when both default");
        assertEq(shareB, DEPOSIT, "No bleeding when both default");
    }

    function test_NoRetroactiveBleedAfterMutualDefault() public {
        _activateBothParties();

        // Both default for 3 intervals (past grace)
        _warp(3 * INTERVAL);

        // Apply bleeding — both are defaulting, so no bleed should occur
        mll.applyBleeding();
        (uint256 shareA, uint256 shareB, , ) = mll.getPoolState();
        assertEq(shareA, DEPOSIT, "No bleeding during mutual default");
        assertEq(shareB, DEPOSIT, "No bleeding during mutual default");

        // Alice resumes — deposits again
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        // Apply bleeding — Bob is now the sole defaulter, but should NOT be back-charged
        // for the mutual-default period. Only bleed from Alice's resume point onward.
        mll.applyBleeding();

        (, uint256 shareB2, , ) = mll.getPoolState();
        // Bob should still have his full DEPOSIT (no retroactive bleed for mutual-default period)
        // The bleed clock was advanced during mutual default, so only new default time counts
        assertEq(shareB2, DEPOSIT, "No retroactive bleed after mutual default");
    }

    function test_Bleed100PercentToCompliant() public {
        _activateBothParties();

        // Mutual default period — both miss deposits
        _warp(3 * INTERVAL);
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        // Warp INTERVAL so Alice stays compliant (periodsMissed=1 <= grace)
        // Bob continues defaulting → bleed applies
        _warp(INTERVAL);

        (uint256 aliceBefore, uint256 bobBefore, , ) = mll.getPoolState();

        mll.applyBleeding();

        (uint256 shareA, uint256 shareB, uint256 total, ) = mll.getPoolState();
        uint256 bobLost = bobBefore - shareB;
        uint256 aliceGained = shareA - aliceBefore;

        assertGt(bobLost, 0, "Bob lost share to bleeding");
        assertEq(aliceGained, bobLost, "100% of bleed goes to Alice (no burn)");
        assertEq(total, aliceBefore + bobBefore, "Total pool unchanged (no burn)");
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

        assertEq(mll.claimable(alice), DEPOSIT);
        assertEq(mll.claimable(bob), DEPOSIT);

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

    function test_UnilateralExitExecutesWithDynamicPenalty() public {
        _activateBothParties();

        vm.prank(alice);
        mll.initiateUnilateralExit();

        _warp(30 days + 1);

        vm.prank(bob);
        mll.deposit{value: DEPOSIT}();

        vm.prank(alice);
        mll.executeUnilateralExit();

        uint256 aliceClaimable = mll.claimable(alice);
        uint256 bobClaimable = mll.claimable(bob);

        // At cold-start (1 deposit), penalty is high (~7072 bps)
        // Alice's share = 1 DEPOSIT, penalty ≈ 70.7% of 1 ETH ≈ 0.707 ETH
        assertLt(aliceClaimable, DEPOSIT, "Alice receives less than deposit due to penalty");
        assertLt(aliceClaimable, DEPOSIT * 4000 / 10000, "Cold-start penalty is much higher than 15%");
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
    //                  DYNAMIC EXIT PENALTY TESTS
    // ============================================================

    function test_DynamicPenaltyAtColdStart() public {
        _activateBothParties();
        // Alice has deposited 1 DEPOSIT total (activation)
        uint256 penalty = mll.getExitPenalty(alice);
        // penalty = 8000 - (8000-1500) * (1/7) = 8000 - 928 = 7072
        assertGt(penalty, 7000, "Cold start penalty should be near P_max");
        assertLt(penalty, EXIT_PENALTY_MAX, "But strictly below P_max since 1 deposit was made");
    }

    function test_DynamicPenaltyAtMaturity() public {
        _activateBothParties();
        // Deposit enough to reach s_target (7 deposits total with activation = 6 more)
        for (uint i = 0; i < 6; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }
        // Alice has deposited 7 DEPOSIT total (1 activation + 6 deposits) = target
        uint256 penalty = mll.getExitPenalty(alice);
        assertEq(penalty, EXIT_PENALTY_MIN, "Mature pool penalty should equal P_min");
    }

    function test_DynamicPenaltyAtMidpoint() public {
        _activateBothParties();
        // Deposit to roughly half of target
        for (uint i = 0; i < 3; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }
        // Alice has deposited 4 DEPOSIT total (1 + 3)
        uint256 penalty = mll.getExitPenalty(alice);
        // 8000 - 6500 * (4/7) = 8000 - 3714 = 4286
        assertGt(penalty, EXIT_PENALTY_MIN, "Midpoint penalty > P_min");
        assertLt(penalty, EXIT_PENALTY_MAX, "Midpoint penalty < P_max");
    }

    function test_DynamicPenaltyTracksPerParty() public {
        _activateBothParties();
        // Alice deposits more than Bob
        for (uint i = 0; i < 5; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
        }
        // Alice: 6 deposits total. Bob: 1 deposit total (activation only)
        uint256 alicePenalty = mll.getExitPenalty(alice);
        uint256 bobPenalty = mll.getExitPenalty(bob);
        assertLt(alicePenalty, bobPenalty, "Alice with more deposits should have lower penalty");
    }

    function test_DynamicPenaltyBeyondTarget() public {
        _activateBothParties();
        // Deposit well beyond target
        for (uint i = 0; i < 10; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }
        // Alice: 11 deposits, well past target of 7
        uint256 penalty = mll.getExitPenalty(alice);
        assertEq(penalty, EXIT_PENALTY_MIN, "Penalty stays at P_min beyond target");
    }

    function test_UnilateralExitMaturePoolLowPenalty() public {
        _activateBothParties();
        // Build up to maturity
        for (uint i = 0; i < 6; i++) {
            _warp(INTERVAL);
            vm.prank(alice);
            mll.deposit{value: DEPOSIT}();
            vm.prank(bob);
            mll.deposit{value: DEPOSIT}();
        }

        // Alice: 7 deposits = target. Penalty should be P_min = 15%
        vm.prank(alice);
        mll.initiateUnilateralExit();
        _warp(30 days + 1);

        // Bob deposits to keep compliant during countdown
        vm.prank(bob);
        mll.deposit{value: DEPOSIT}();

        vm.prank(alice);
        mll.executeUnilateralExit();

        uint256 aliceClaimable = mll.claimable(alice);
        // Alice's share = 7 DEPOSIT. Penalty = 15% of 7 = 1.05 ETH.
        // Alice receives 85% of 7 = 5.95 ETH
        assertGt(aliceClaimable, 7 * DEPOSIT * 8000 / 10000, "Mature exit: Alice retains >80%");
        assertLt(aliceClaimable, 7 * DEPOSIT, "Alice still pays some penalty");
    }

    // ============================================================
    //                  DEAD MAN'S SWITCH TESTS
    // ============================================================

    function test_ClaimAbandonedClearsPendingExit() public {
        _activateBothParties();

        // Alice initiates unilateral exit
        vm.prank(alice);
        mll.initiateUnilateralExit();

        (, , bool active) = mll.pendingExit();
        assertTrue(active, "Exit should be pending");

        // Bob disappears for 91 days, Alice deposits to stay active
        _warp(91 days);
        vm.prank(alice);
        mll.deposit{value: DEPOSIT}();

        // Alice claims abandoned
        vm.prank(alice);
        mll.claimAbandoned();

        // pendingExit should be cleared
        (, , bool activeAfter) = mll.pendingExit();
        assertFalse(activeAfter, "pendingExit should be cleared after abandonment");
    }

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

        _warp(91 days);

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

    function test_PoolBalanceEqualsShares() public {
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
            // With 100% transfer (no burn), balance should equal shares exactly
            assertEq(address(mll).balance, total, "Contract balance == total shares (no burn)");
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
}
