// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RussianRouletteTestable} from "./RussianRouletteTestable.sol";

/// @title MLL Testable — identical logic, shortened time constants for on-chain integration testing
/// @dev Changes from production contract:
///   - Bleeding time unit: 1 days → depositInterval (so 60s interval = 60s bleed quantum)
///   - Freeze duration: 3650 days → 5 minutes
///   - Exit countdown: 30 days → 2 minutes
///   - Cancel inactive: 7 days → 2 minutes
///   - Abandonment: 90 days → 3 minutes

contract MutualLiquidityLockTestable is RussianRouletteTestable {

    enum Phase { Inactive, Active, Frozen, Exited }

    struct Agreement {
        address partyA;
        address partyB;
        uint256 depositAmount;
        uint256 depositInterval;
        uint256 bleedRatePerDay;     // bps per bleed-time-unit (= depositInterval in testable)
        uint256 gracePeriodsAllowed;
        uint256 freezeDuration;
        uint256 exitPenaltyBps;
        uint256 exitCountdown;
        Phase phase;
        uint256 createdAt;
        uint256 activatedAt;
    }

    struct PartyState {
        uint256 share;
        uint256 lastDepositTime;
        uint256 lastBleedApplied;
        uint256 missedPeriods;
        bool exitProposed;
    }

    struct UnilateralExit {
        address initiator;
        uint256 executeAfter;
        bool active;
    }

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    uint256 public constant SHARE_GATE_BPS = 3500;
    uint256 public constant BLEED_COUNTERPARTY_BPS = 7000;
    uint256 public constant BLEED_BURN_BPS = 3000;
    uint256 public constant WARMUP_PERIODS = 3;
    uint256 public constant DECAY_PERIODS = 6;
    uint256 public constant MAX_DEPOSIT_MULTIPLIER = 3;
    uint256 public constant ABANDONMENT_MIN_INTERVALS = 3;

    // ============================================================
    //                         STORAGE
    // ============================================================

    Agreement public agreement;
    mapping(address => PartyState) public parties;
    mapping(address => uint256) public claimable;
    UnilateralExit public pendingExit;
    uint256 public frozenAt;

    // ============================================================
    //                         EVENTS
    // ============================================================

    event AgreementCreated(address indexed partyA, address indexed partyB, uint256 depositAmount, uint256 interval);
    event Deposited(address indexed party, uint256 amount, uint256 newShare);
    event BleedingApplied(address indexed from, address indexed to, uint256 toAmount, uint256 burnedAmount);
    event ExitProposed(address indexed party);
    event ExitProposalCancelled(address indexed party);
    event PeacefulExit(uint256 shareA, uint256 shareB);
    event AgreementActivated(uint256 activatedAt);
    event AgreementFrozen(uint256 totalPool, uint256 invocationCount, uint256 unfreezeAt);
    event UnilateralExitInitiated(address indexed initiator, uint256 executeAfter);
    event UnilateralExitCancelled(address indexed canceller);
    event UnilateralExitExecuted(address indexed initiator, uint256 received, uint256 penaltyPaid);
    event FrozenFundsReleased(uint256 shareA, uint256 shareB);
    event AbandonedClaimed(address indexed claimer, uint256 amount);
    event InactiveCancelled(address indexed party, uint256 refund);
    event Withdrawn(address indexed party, uint256 amount);

    // ============================================================
    //                         ERRORS
    // ============================================================

    error NotParty();
    error WrongPhase(Phase expected, Phase actual);
    error WarmupPeriodActive(uint256 endsAt);
    error ShareBelowGate(uint256 shareBps, uint256 requiredBps);
    error ExitCountdownNotElapsed(uint256 executeAfter);
    error NoActiveUnilateralExit();
    error UnilateralExitAlreadyActive();
    error FreezeNotExpired(uint256 unfreezeAt);
    error NothingToWithdraw();

    // ============================================================
    //                        MODIFIERS
    // ============================================================

    modifier onlyParty() {
        if (msg.sender != agreement.partyA && msg.sender != agreement.partyB)
            revert NotParty();
        _;
    }

    modifier inPhase(Phase expected) {
        if (agreement.phase != expected)
            revert WrongPhase(expected, agreement.phase);
        _;
    }

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    constructor(
        address _partyA,
        address _partyB,
        uint256 _depositAmount,
        uint256 _depositInterval,
        uint256 _bleedRateBpsPerDay,
        uint256 _gracePeriods
    ) {
        require(_partyA != address(0), "Invalid partyA");
        require(_partyB != address(0) && _partyB != _partyA, "Invalid partyB");
        require(_depositAmount > 0, "Deposit must be > 0");
        require(_depositInterval >= 1 minutes, "Interval too short");
        require(_bleedRateBpsPerDay > 0 && _bleedRateBpsPerDay <= 1000, "Bleed rate out of range");
        require(_gracePeriods <= 12, "Too many grace periods");

        agreement = Agreement({
            partyA: _partyA,
            partyB: _partyB,
            depositAmount: _depositAmount,
            depositInterval: _depositInterval,
            bleedRatePerDay: _bleedRateBpsPerDay,
            gracePeriodsAllowed: _gracePeriods,
            freezeDuration: 5 minutes,      // TESTABLE: was 3650 days
            exitPenaltyBps: 1500,
            exitCountdown: 2 minutes,        // TESTABLE: was 30 days
            phase: Phase.Inactive,
            createdAt: block.timestamp,
            activatedAt: 0
        });

        emit AgreementCreated(_partyA, _partyB, _depositAmount, _depositInterval);
    }

    // ============================================================
    //                    ACTIVATION
    // ============================================================

    function activate() external payable onlyParty inPhase(Phase.Inactive) {
        require(msg.value >= agreement.depositAmount, "Must deposit agreed amount");

        PartyState storage ps = parties[msg.sender];
        require(ps.share == 0, "Already deposited");

        ps.share = msg.value;
        ps.lastDepositTime = block.timestamp;
        ps.lastBleedApplied = block.timestamp;

        address other = _otherParty(msg.sender);
        if (parties[other].share > 0) {
            agreement.phase = Phase.Active;
            agreement.activatedAt = block.timestamp;

            PartyState storage otherPs = parties[other];
            otherPs.lastDepositTime = block.timestamp;
            otherPs.lastBleedApplied = block.timestamp;

            emit AgreementActivated(block.timestamp);
        }

        emit Deposited(msg.sender, msg.value, ps.share);
    }

    function cancelInactive() external onlyParty inPhase(Phase.Inactive) {
        require(block.timestamp > agreement.createdAt + 2 minutes, "Too early to cancel");  // TESTABLE: was 7 days

        PartyState storage ps = parties[msg.sender];
        uint256 refund = ps.share;
        require(refund > 0, "Nothing to refund");

        ps.share = 0;
        agreement.phase = Phase.Exited;

        emit InactiveCancelled(msg.sender, refund);

        claimable[msg.sender] += refund;
    }

    // ============================================================
    //                    DEPOSIT
    // ============================================================

    function deposit() external payable onlyParty inPhase(Phase.Active) {
        require(msg.value >= agreement.depositAmount, "Below minimum deposit");
        require(msg.value <= agreement.depositAmount * MAX_DEPOSIT_MULTIPLIER, "Exceeds max deposit");

        _applyBleeding();

        PartyState storage ps = parties[msg.sender];
        ps.share += msg.value;
        ps.lastDepositTime = block.timestamp;
        ps.lastBleedApplied = block.timestamp;
        ps.missedPeriods = 0;

        emit Deposited(msg.sender, msg.value, ps.share);
    }

    // ============================================================
    //                    WITHDRAWAL (pull pattern)
    // ============================================================

    function withdraw() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        claimable[msg.sender] = 0;

        emit Withdrawn(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // ============================================================
    //                    BLEEDING MECHANISM
    // ============================================================

    function applyBleeding() external inPhase(Phase.Active) {
        _applyBleeding();
    }

    function _applyBleeding() internal {
        _applyBleedingFor(agreement.partyA, agreement.partyB);
        _applyBleedingFor(agreement.partyB, agreement.partyA);
    }

    function _applyBleedingFor(address defaulter, address compliant) internal {
        PartyState storage dps = parties[defaulter];
        PartyState storage cps = parties[compliant];

        uint256 elapsed = block.timestamp - dps.lastDepositTime;
        uint256 periodsMissed = elapsed / agreement.depositInterval;

        if (periodsMissed <= agreement.gracePeriodsAllowed) return;

        uint256 otherElapsed = block.timestamp - cps.lastDepositTime;
        uint256 otherMissed = otherElapsed / agreement.depositInterval;
        if (otherMissed > agreement.gracePeriodsAllowed) return;

        uint256 graceEnd = dps.lastDepositTime + agreement.gracePeriodsAllowed * agreement.depositInterval;
        uint256 bleedStart = dps.lastBleedApplied > graceEnd ? dps.lastBleedApplied : graceEnd;

        if (block.timestamp <= bleedStart) return;

        // TESTABLE: use depositInterval instead of 1 days
        uint256 newBleedPeriods = (block.timestamp - bleedStart) / agreement.depositInterval;
        if (newBleedPeriods == 0) return;

        uint256 effectiveRate = _getEffectiveBleedRate();

        uint256 remainingBps = 10000 - effectiveRate;
        uint256 retainedFraction = _compoundBps(remainingBps, newBleedPeriods);

        uint256 bleedAmount = dps.share - (dps.share * retainedFraction / 1e18);

        if (bleedAmount > 0 && bleedAmount <= dps.share) {
            dps.share -= bleedAmount;

            uint256 toCounterparty = bleedAmount * BLEED_COUNTERPARTY_BPS / 10000;

            cps.share += toCounterparty;

            dps.missedPeriods = periodsMissed - agreement.gracePeriodsAllowed;
            dps.lastBleedApplied = block.timestamp;

            emit BleedingApplied(defaulter, compliant, toCounterparty, bleedAmount - toCounterparty);
        }
    }

    function _getEffectiveBleedRate() internal view returns (uint256) {
        uint256 age = block.timestamp - agreement.activatedAt;
        uint256 decayEnd = DECAY_PERIODS * agreement.depositInterval;

        if (age >= decayEnd) {
            return agreement.bleedRatePerDay;
        }

        uint256 multiplierX1e18 = (2 * decayEnd - age) * 1e18 / decayEnd;
        uint256 effectiveRate = agreement.bleedRatePerDay * multiplierX1e18 / 1e18;

        if (effectiveRate > 1000) effectiveRate = 1000;

        return effectiveRate;
    }

    function _compoundBps(uint256 bps, uint256 n) internal pure returns (uint256) {
        if (n == 0) return 1e18;

        uint256 base = bps * 1e14;
        uint256 result = 1e18;

        while (n > 0) {
            if (n % 2 == 1) {
                result = result * base / 1e18;
            }
            base = base * base / 1e18;
            n /= 2;
        }

        return result;
    }

    // ============================================================
    //                    RUSSIAN ROULETTE
    // ============================================================

    function invokeRoulette() external payable onlyParty inPhase(Phase.Active) {
        uint256 warmupEnd = agreement.activatedAt + WARMUP_PERIODS * agreement.depositInterval;
        if (block.timestamp <= warmupEnd)
            revert WarmupPeriodActive(warmupEnd);

        require(msg.value >= agreement.depositAmount, "Must deposit to invoke RR");
        require(msg.value <= agreement.depositAmount * MAX_DEPOSIT_MULTIPLIER, "Exceeds max deposit");

        _applyBleeding();

        PartyState storage ps = parties[msg.sender];
        ps.share += msg.value;
        ps.lastDepositTime = block.timestamp;
        ps.lastBleedApplied = block.timestamp;

        uint256 totalPool = parties[agreement.partyA].share + parties[agreement.partyB].share;
        uint256 invokerShareBps = ps.share * 10000 / totalPool;
        if (invokerShareBps < SHARE_GATE_BPS)
            revert ShareBelowGate(invokerShareBps, SHARE_GATE_BPS);

        bool triggered = _invokeRR(msg.sender);

        if (triggered) {
            _freezePool();
        }
    }

    function _freezePool() internal {
        agreement.phase = Phase.Frozen;
        frozenAt = block.timestamp;
        uint256 total = parties[agreement.partyA].share + parties[agreement.partyB].share;
        uint256 unfreezeAt = block.timestamp + agreement.freezeDuration;
        emit AgreementFrozen(total, rrState.invocationCount, unfreezeAt);
    }

    function releaseFrozenFunds() external onlyParty inPhase(Phase.Frozen) {
        uint256 unfreezeAt = frozenAt + agreement.freezeDuration;
        if (block.timestamp < unfreezeAt)
            revert FreezeNotExpired(unfreezeAt);

        agreement.phase = Phase.Exited;

        uint256 shareA = parties[agreement.partyA].share;
        uint256 shareB = parties[agreement.partyB].share;

        parties[agreement.partyA].share = 0;
        parties[agreement.partyB].share = 0;

        emit FrozenFundsReleased(shareA, shareB);

        claimable[agreement.partyA] += shareA;
        claimable[agreement.partyB] += shareB;
    }

    // ============================================================
    //                    PEACEFUL EXIT (bilateral)
    // ============================================================

    function proposeExit() external onlyParty inPhase(Phase.Active) {
        _applyBleeding();

        PartyState storage ps = parties[msg.sender];
        ps.exitProposed = true;
        emit ExitProposed(msg.sender);

        address other = _otherParty(msg.sender);
        if (parties[other].exitProposed) {
            _executePeacefulExit();
        }
    }

    function cancelExitProposal() external onlyParty inPhase(Phase.Active) {
        parties[msg.sender].exitProposed = false;
        emit ExitProposalCancelled(msg.sender);
    }

    function _executePeacefulExit() internal {
        agreement.phase = Phase.Exited;

        if (pendingExit.active) {
            delete pendingExit;
        }

        uint256 shareA = parties[agreement.partyA].share;
        uint256 shareB = parties[agreement.partyB].share;

        parties[agreement.partyA].share = 0;
        parties[agreement.partyB].share = 0;

        emit PeacefulExit(shareA, shareB);

        claimable[agreement.partyA] += shareA;
        claimable[agreement.partyB] += shareB;
    }

    // ============================================================
    //                    UNILATERAL EXIT
    // ============================================================

    function initiateUnilateralExit() external onlyParty inPhase(Phase.Active) {
        if (pendingExit.active) revert UnilateralExitAlreadyActive();

        _applyBleeding();

        uint256 executeAfter = block.timestamp + agreement.exitCountdown;
        pendingExit = UnilateralExit({
            initiator: msg.sender,
            executeAfter: executeAfter,
            active: true
        });

        emit UnilateralExitInitiated(msg.sender, executeAfter);
    }

    function cancelUnilateralExit() external onlyParty inPhase(Phase.Active) {
        if (!pendingExit.active) revert NoActiveUnilateralExit();
        require(msg.sender == pendingExit.initiator, "Only initiator can cancel");

        delete pendingExit;
        emit UnilateralExitCancelled(msg.sender);
    }

    function executeUnilateralExit() external onlyParty inPhase(Phase.Active) {
        if (!pendingExit.active) revert NoActiveUnilateralExit();
        if (block.timestamp < pendingExit.executeAfter)
            revert ExitCountdownNotElapsed(pendingExit.executeAfter);

        _applyBleeding();

        address initiator = pendingExit.initiator;
        address other = _otherParty(initiator);

        PartyState storage ips = parties[initiator];
        PartyState storage ops = parties[other];

        uint256 penalty = ips.share * agreement.exitPenaltyBps / 10000;
        ips.share -= penalty;
        ops.share += penalty;

        agreement.phase = Phase.Exited;
        delete pendingExit;

        uint256 initiatorShare = ips.share;
        uint256 otherShare = ops.share;

        ips.share = 0;
        ops.share = 0;

        emit UnilateralExitExecuted(initiator, initiatorShare, penalty);

        claimable[initiator] += initiatorShare;
        claimable[other] += otherShare;
    }

    // ============================================================
    //                    DEAD MAN'S SWITCH
    // ============================================================

    function claimAbandoned() external onlyParty inPhase(Phase.Active) {
        address other = _otherParty(msg.sender);
        PartyState storage otherPs = parties[other];
        PartyState storage myPs = parties[msg.sender];

        // TESTABLE: abandonment threshold = max(3 minutes, 3 * depositInterval)
        uint256 abandonmentThreshold = 3 minutes;
        uint256 intervalThreshold = ABANDONMENT_MIN_INTERVALS * agreement.depositInterval;
        if (intervalThreshold > abandonmentThreshold) {
            abandonmentThreshold = intervalThreshold;
        }

        require(
            block.timestamp - otherPs.lastDepositTime > abandonmentThreshold,
            "Counterparty still active"
        );
        require(
            myPs.lastDepositTime > otherPs.lastDepositTime,
            "Claimer must be more active than counterparty"
        );

        _applyBleeding();

        agreement.phase = Phase.Exited;

        uint256 total = parties[agreement.partyA].share + parties[agreement.partyB].share;
        parties[agreement.partyA].share = 0;
        parties[agreement.partyB].share = 0;

        emit AbandonedClaimed(msg.sender, total);

        claimable[msg.sender] += total;
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    function getPoolState() external view returns (
        uint256 shareA,
        uint256 shareB,
        uint256 totalPool,
        Phase phase
    ) {
        shareA = parties[agreement.partyA].share;
        shareB = parties[agreement.partyB].share;
        totalPool = shareA + shareB;
        phase = agreement.phase;
    }

    function getMissedPeriods(address party) external view returns (uint256) {
        uint256 elapsed = block.timestamp - parties[party].lastDepositTime;
        return elapsed / agreement.depositInterval;
    }

    function getEffectiveBleedRate() external view returns (uint256) {
        return _getEffectiveBleedRate();
    }

    function getUnfreezeTime() external view returns (uint256) {
        if (agreement.phase != Phase.Frozen) return 0;
        return frozenAt + agreement.freezeDuration;
    }

    // ============================================================
    //                    INTERNAL HELPERS
    // ============================================================

    function _otherParty(address party) internal view returns (address) {
        return party == agreement.partyA ? agreement.partyB : agreement.partyA;
    }

    receive() external payable {
        revert("Use deposit() or activate()");
    }
}
