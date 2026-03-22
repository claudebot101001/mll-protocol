// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Russian Roulette Testable — identical logic, shortened cooldown (2 min vs 10 days)

abstract contract RussianRouletteTestable {

    struct RRState {
        uint256 invocationCount;
        uint256 cooldownEnd;
        address lastInvoker;
        bool pendingResult;
    }

    uint256 public constant MAX_INVOCATIONS = 6;
    uint256 public constant COOLDOWN_PERIOD = 2 minutes;  // TESTABLE: was 10 days

    RRState public rrState;

    event RoulettePulled(address indexed invoker, uint256 invocationCount, uint256 triggerProbabilityBps);
    event RouletteResult(uint256 invocationCount, bool triggered);
    event CooldownStarted(uint256 cooldownEnd);

    error CooldownActive(uint256 endsAt);
    error MaxInvocationsReached();
    error RRPendingResult();

    function _canInvokeRR() internal view returns (bool) {
        if (rrState.pendingResult) return false;
        if (rrState.invocationCount >= MAX_INVOCATIONS) return false;
        if (block.timestamp < rrState.cooldownEnd) return false;
        return true;
    }

    function _invokeRR(address invoker) internal returns (bool triggered) {
        if (rrState.pendingResult) revert RRPendingResult();
        if (rrState.invocationCount >= MAX_INVOCATIONS) revert MaxInvocationsReached();
        if (block.timestamp < rrState.cooldownEnd) revert CooldownActive(rrState.cooldownEnd);

        rrState.invocationCount++;
        rrState.lastInvoker = invoker;

        uint256 k = rrState.invocationCount;

        uint256 denominator = 7 - k;

        uint256 triggerProbBps = 10000 / denominator;
        emit RoulettePulled(invoker, k, triggerProbBps);

        if (denominator == 1) {
            triggered = true;
        } else {
            uint256 random = uint256(keccak256(abi.encodePacked(
                block.prevrandao,
                block.timestamp,
                invoker,
                k
            )));

            triggered = (random % denominator == 0);
        }

        emit RouletteResult(k, triggered);

        if (!triggered) {
            rrState.cooldownEnd = block.timestamp + COOLDOWN_PERIOD;
            emit CooldownStarted(rrState.cooldownEnd);
        }

        return triggered;
    }

    function getRRProbability() external view returns (uint256 probabilityBps, uint256 invocationsUsed) {
        invocationsUsed = rrState.invocationCount;
        if (invocationsUsed >= MAX_INVOCATIONS) {
            probabilityBps = 10000;
        } else {
            probabilityBps = 10000 / (7 - invocationsUsed - 1);
        }
    }

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
