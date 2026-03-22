// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RussianRoulette} from "./RussianRoulette.sol";

/// @title Mutual Liquidity Lock (MLL)
/// @notice Bilateral commitment device with bleeding penalty, Russian Roulette, and multi-path exit
/// @dev Implements: share gate, 70/30 bleed split, unilateral exit, configurable freeze, decaying bleed rate
///      Uses pull-based withdrawals to prevent DoS by contract parties

contract MutualLiquidityLock is RussianRoulette {

    // ============================================================
    //                         TYPES
    // ============================================================

    enum Phase { Inactive, Active, Frozen, Exited }

    struct Agreement {
        address partyA;
        address partyB;
        uint256 depositAmount;       // agreed deposit per period (wei)
        uint256 depositInterval;     // seconds between required deposits
        uint256 bleedRatePerDay;     // basis points per day at steady state (e.g., 50 = 0.5%)
        uint256 gracePeriodsAllowed; // missed periods before bleeding starts
        uint256 freezeDuration;      // seconds funds remain locked after RR trigger (default 10 years)
        uint256 exitPenaltyBps;      // unilateral exit penalty in bps (e.g., 1500 = 15%)
        uint256 exitCountdown;       // seconds of countdown for unilateral exit (e.g., 30 days)
        Phase phase;
        uint256 createdAt;
        uint256 activatedAt;         // timestamp when both parties activated (0 if not yet)
    }

    struct PartyState {
        uint256 share;               // current claim on pool (wei)
        uint256 lastDepositTime;     // timestamp of last deposit
        uint256 lastBleedApplied;    // timestamp up to which bleeding has been applied
        uint256 missedPeriods;       // consecutive missed deposit periods
        bool exitProposed;           // has this party proposed peaceful exit?
    }

    struct UnilateralExit {
        address initiator;           // who initiated the unilateral exit
        uint256 executeAfter;        // timestamp when exit can be executed
        bool active;                 // is there a pending unilateral exit?
    }

    // ============================================================
    //                        CONSTANTS
    // ============================================================

    uint256 public constant SHARE_GATE_BPS = 3500;       // 35% minimum share to invoke RR
    uint256 public constant BLEED_COUNTERPARTY_BPS = 7000; // 70% of bleed goes to counterparty
    uint256 public constant BLEED_BURN_BPS = 3000;         // 30% of bleed is permanently burned
    uint256 public constant WARMUP_PERIODS = 3;            // RR blocked for first 3 deposit intervals
    uint256 public constant DECAY_PERIODS = 6;             // bleeding rate decays from 2x to 1x over 6 intervals
    uint256 public constant MAX_DEPOSIT_MULTIPLIER = 3;    // max deposit = 3x agreed amount per tx
    uint256 public constant ABANDONMENT_MIN_DAYS = 90 days;
    uint256 public constant ABANDONMENT_MIN_INTERVALS = 3; // at least 3 missed intervals for abandonment

    // ============================================================
    //                         STORAGE
    // ============================================================

    Agreement public agreement;
    mapping(address => PartyState) public parties;
    mapping(address => uint256) public claimable;  // pull-based withdrawal balances
    UnilateralExit public pendingExit;
    uint256 public frozenAt;         // timestamp when pool was frozen (0 if not frozen)

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

    /// @param _partyA Address of the first party (deployer role)
    /// @param _partyB Address of the counterparty
    /// @param _depositAmount Required deposit per period in wei
    /// @param _depositInterval Seconds between required deposits (e.g., 30 days = 2592000)
    /// @param _bleedRateBpsPerDay Steady-state bleeding rate in bps/day (e.g., 50 = 0.5%/day)
    /// @param _gracePeriods Number of missed periods before bleeding activates
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
            freezeDuration: 3650 days,      // 10 years default
            exitPenaltyBps: 1500,           // 15% default
            exitCountdown: 30 days,         // 30 days default
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
            // Both parties have deposited — activate the agreement
            agreement.phase = Phase.Active;
            agreement.activatedAt = block.timestamp;

            // Reset first activator's clocks to activation time
            // This prevents charging them for time spent waiting in Inactive
            PartyState storage otherPs = parties[other];
            otherPs.lastDepositTime = block.timestamp;
            otherPs.lastBleedApplied = block.timestamp;

            emit AgreementActivated(block.timestamp);
        }

        emit Deposited(msg.sender, msg.value, ps.share);
    }

    /// @notice Cancel an inactive agreement if counterparty never activated (after 7 days)
    function cancelInactive() external onlyParty inPhase(Phase.Inactive) {
        require(block.timestamp > agreement.createdAt + 7 days, "Too early to cancel");

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

    /// @notice Withdraw claimable funds (pull-based, prevents DoS)
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

    /// @dev Apply bleeding with 70/30 split and decaying rate
    function _applyBleedingFor(address defaulter, address compliant) internal {
        PartyState storage dps = parties[defaulter];
        PartyState storage cps = parties[compliant];

        uint256 elapsed = block.timestamp - dps.lastDepositTime;
        uint256 periodsMissed = elapsed / agreement.depositInterval;

        if (periodsMissed <= agreement.gracePeriodsAllowed) return;

        // No directional bleed if both are defaulting
        uint256 otherElapsed = block.timestamp - cps.lastDepositTime;
        uint256 otherMissed = otherElapsed / agreement.depositInterval;
        if (otherMissed > agreement.gracePeriodsAllowed) return;

        // Incremental bleeding
        uint256 graceEnd = dps.lastDepositTime + agreement.gracePeriodsAllowed * agreement.depositInterval;
        uint256 bleedStart = dps.lastBleedApplied > graceEnd ? dps.lastBleedApplied : graceEnd;

        if (block.timestamp <= bleedStart) return;

        uint256 newBleedDays = (block.timestamp - bleedStart) / 1 days;
        if (newBleedDays == 0) return;

        uint256 effectiveRate = _getEffectiveBleedRate();

        uint256 remainingBps = 10000 - effectiveRate;
        uint256 retainedFraction = _compoundBps(remainingBps, newBleedDays);

        uint256 bleedAmount = dps.share - (dps.share * retainedFraction / 1e18);

        if (bleedAmount > 0 && bleedAmount <= dps.share) {
            dps.share -= bleedAmount;

            uint256 toCounterparty = bleedAmount * BLEED_COUNTERPARTY_BPS / 10000;
            // remainder is permanently burned (stays in contract, never attributed)

            cps.share += toCounterparty;

            dps.missedPeriods = periodsMissed - agreement.gracePeriodsAllowed;
            dps.lastBleedApplied = block.timestamp;

            emit BleedingApplied(defaulter, compliant, toCounterparty, bleedAmount - toCounterparty);
        }
    }

    /// @dev Returns the effective bleeding rate, accounting for early-period decay
    /// Uses activatedAt as the reference point, not createdAt
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

    /// @notice Invoke RR. Requires: past warmup, deposit d, and >= 35% pool share.
    /// Warmup is anchored to activatedAt, not createdAt
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

    /// @notice After freeze duration expires, either party can release funds
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

        // Clear any pending unilateral exit
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

    /// @notice Initiate unilateral exit with countdown period.
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

    /// @notice Cancel a pending unilateral exit (only the initiator can cancel)
    function cancelUnilateralExit() external onlyParty inPhase(Phase.Active) {
        if (!pendingExit.active) revert NoActiveUnilateralExit();
        require(msg.sender == pendingExit.initiator, "Only initiator can cancel");

        delete pendingExit;
        emit UnilateralExitCancelled(msg.sender);
    }

    /// @notice Execute unilateral exit after countdown. Either party can execute.
    /// The initiator pays a percentage penalty from their share to the counterparty.
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

    /// @notice Claim funds when counterparty has been inactive for an extended period.
    /// Requires: counterparty inactive for max(90 days, 3 * depositInterval),
    /// AND claimer must have deposited more recently than the counterparty.
    function claimAbandoned() external onlyParty inPhase(Phase.Active) {
        address other = _otherParty(msg.sender);
        PartyState storage otherPs = parties[other];
        PartyState storage myPs = parties[msg.sender];

        // Abandonment threshold is the greater of 90 days or 3 deposit intervals
        uint256 abandonmentThreshold = ABANDONMENT_MIN_DAYS;
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

    /// @dev Reject direct ETH transfers
    receive() external payable {
        revert("Use deposit() or activate()");
    }
}
