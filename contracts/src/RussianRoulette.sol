// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Russian Roulette Module for MLL
/// @notice Graduated destruction mechanism using on-demand randomness
/// @dev Designed to work with Chainlink VRF v2.5 for production.
///      This MVP uses a simplified pseudo-random approach for testing.

abstract contract RussianRoulette {

    // ============================================================
    //                         TYPES
    // ============================================================

    struct RRState {
        uint256 invocationCount;     // k: number of times RR has been triggered
        uint256 cooldownEnd;         // timestamp when cooldown expires
        address lastInvoker;         // who triggered the last invocation
        bool pendingResult;          // waiting for VRF callback
    }

    // ============================================================
    //                         CONSTANTS
    // ============================================================

    uint256 public constant MAX_INVOCATIONS = 6;
    uint256 public constant COOLDOWN_PERIOD = 10 days;

    // ============================================================
    //                         STATE
    // ============================================================

    RRState public rrState;

    // ============================================================
    //                         EVENTS
    // ============================================================

    event RoulettePulled(address indexed invoker, uint256 invocationCount, uint256 triggerProbabilityBps);
    event RouletteResult(uint256 invocationCount, bool triggered);
    event CooldownStarted(uint256 cooldownEnd);

    // ============================================================
    //                         ERRORS
    // ============================================================

    error CooldownActive(uint256 endsAt);
    error MaxInvocationsReached();
    error RRPendingResult();

    // ============================================================
    //                      INTERNAL LOGIC
    // ============================================================

    /// @dev Check if Russian Roulette can be invoked
    function _canInvokeRR() internal view returns (bool) {
        if (rrState.pendingResult) return false;
        if (rrState.invocationCount >= MAX_INVOCATIONS) return false;
        if (block.timestamp < rrState.cooldownEnd) return false;
        return true;
    }

    /// @dev Invoke Russian Roulette. Returns true if triggered (funds should freeze).
    /// @notice In production, this should request Chainlink VRF and resolve in callback.
    ///         This MVP uses block-based pseudo-randomness for testing only.
    function _invokeRR(address invoker) internal returns (bool triggered) {
        if (rrState.pendingResult) revert RRPendingResult();
        if (rrState.invocationCount >= MAX_INVOCATIONS) revert MaxInvocationsReached();
        if (block.timestamp < rrState.cooldownEnd) revert CooldownActive(rrState.cooldownEnd);

        rrState.invocationCount++;
        rrState.lastInvoker = invoker;

        uint256 k = rrState.invocationCount;

        // Trigger probability: 1/(7-k)
        // At k=1: 1/6, k=2: 1/5, k=3: 1/4, k=4: 1/3, k=5: 1/2, k=6: 1/1
        uint256 denominator = 7 - k;

        uint256 triggerProbBps = 10000 / denominator;
        emit RoulettePulled(invoker, k, triggerProbBps);

        if (denominator == 1) {
            // k=6: certain trigger
            triggered = true;
        } else {
            // MVP: pseudo-random (NOT production-safe)
            // In production: request Chainlink VRF here, set pendingResult = true,
            // and resolve in fulfillRandomWords callback
            uint256 random = uint256(keccak256(abi.encodePacked(
                block.prevrandao,
                block.timestamp,
                invoker,
                k
            )));

            // triggered if random % denominator == 0 (probability 1/denominator)
            triggered = (random % denominator == 0);
        }

        emit RouletteResult(k, triggered);

        if (!triggered) {
            // Start cooldown
            rrState.cooldownEnd = block.timestamp + COOLDOWN_PERIOD;
            emit CooldownStarted(rrState.cooldownEnd);
        }

        return triggered;
    }

    /// @dev Get the current trigger probability in basis points
    function getRRProbability() external view returns (uint256 probabilityBps, uint256 invocationsUsed) {
        invocationsUsed = rrState.invocationCount;
        if (invocationsUsed >= MAX_INVOCATIONS) {
            probabilityBps = 10000; // 100%
        } else {
            probabilityBps = 10000 / (7 - invocationsUsed - 1);
        }
    }

    /// @dev Get the current RR state
    function getRRState() external view returns (
        uint256 invocationCount,
        uint256 cooldownEnd,
        address lastInvoker,
        bool canInvoke
    ) {
        return (
            rrState.invocationCount,
            rrState.cooldownEnd,
            rrState.lastInvoker,
            _canInvokeRR()
        );
    }
}
