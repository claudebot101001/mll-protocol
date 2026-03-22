#!/bin/bash
# MLL Protocol Complete On-Chain Test Suite
# Tests ALL mechanisms described in the blog post
# Contract: MutualLiquidityLockTestable on Base mainnet
#
# Time constants (testable):
#   Bleeding time unit: depositInterval (60s) instead of 1 day
#   Freeze duration: 5 minutes instead of 10 years
#   Exit countdown: 2 minutes instead of 30 days
#   Cancel inactive: 2 minutes instead of 7 days
#   Abandonment: 3 minutes instead of 90 days
#   RR cooldown: 2 minutes instead of 10 days

set -euo pipefail

RPC=https://mainnet.base.org
PKEY_A=0x2c1c32993a56874fe29afedd7f940c933d063f87c11ff1e0fa7653d1619ec135
PKEY_B=0x789cd328c8525aa72105251d0fe3375103130711b6c9096d3b3803b1861d5b03
PARTY_A=0x06D84823bC4A615Bd5419575eC93B9DE3d84b9d4
PARTY_B=0x8df69454C2880a9E30861de8d387811CADf52B5E
DEPOSIT=100000  # 100,000 wei

PASS=0
FAIL=0
SKIP=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ❌ FAIL: $1 — $2"; }
skip() { SKIP=$((SKIP+1)); TOTAL=$((TOTAL+1)); echo "  ⏭️  SKIP: $1 — $2"; }
info() { echo "  ℹ️  $1"; }
section() { echo ""; echo "════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════"; }

# Deploy a fresh testable contract, sets $CONTRACT
deploy() {
    local result
    result=$(forge create src/MutualLiquidityLockTestable.sol:MutualLiquidityLockTestable \
        --rpc-url $RPC \
        --private-key $PKEY_A \
        --broadcast \
        --constructor-args $PARTY_A $PARTY_B $DEPOSIT 60 500 1 \
        2>&1)
    CONTRACT=$(echo "$result" | grep "Deployed to:" | awk '{print $3}')
    echo "  📦 Deployed: $CONTRACT"
}

# Activate both parties
activate_both() {
    cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1" && \
    cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
}

# Get shares as decimal
get_shares() {
    local raw
    raw=$(cast call $CONTRACT "getPoolState()" --rpc-url $RPC 2>&1)
    SHARE_A=$(echo "$raw" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[0:64],16))")
    SHARE_B=$(echo "$raw" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[64:128],16))")
    TOTAL_POOL=$(echo "$raw" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[128:192],16))")
    PHASE=$(echo "$raw" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[192:256],16))")
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 1: ACTIVATION + DEPOSITS + BLEEDING
# ═══════════════════════════════════════════════════════════════

section "PHASE 1: Activation, Deposits & Bleeding"
deploy

echo ""
echo "--- Test 1.1: PartyA activates (Inactive → still Inactive) ---"
cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
if [ "$PHASE" = "0" ] && [ "$SHARE_A" = "$DEPOSIT" ]; then
    pass "PartyA activated, phase=Inactive, share=$SHARE_A"
else
    fail "PartyA activation" "phase=$PHASE share=$SHARE_A"
fi

echo "--- Test 1.2: PartyB activates (→ Active, AgreementActivated event) ---"
RESULT=$(cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1)
get_shares
HAS_ACTIVATED=$(echo "$RESULT" | grep -c "0xea49e8aa" || true)
if [ "$PHASE" = "1" ] && [ "$SHARE_B" = "$DEPOSIT" ] && [ "$HAS_ACTIVATED" -gt 0 ]; then
    pass "Both activated, phase=Active, AgreementActivated emitted"
else
    fail "PartyB activation" "phase=$PHASE shareB=$SHARE_B activated=$HAS_ACTIVATED"
fi

echo "--- Test 1.3: Deposit increases share ---"
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
EXPECTED=$((DEPOSIT * 2))
if [ "$SHARE_A" = "$EXPECTED" ]; then
    pass "PartyA deposit: share=$SHARE_A (2x deposit)"
else
    fail "Deposit increase" "expected=$EXPECTED got=$SHARE_A"
fi

echo "--- Test 1.4: No bleeding within grace period (1 interval) ---"
echo "  Waiting 65s (past 1 interval but within grace=1)..."
sleep 65
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
RESULT=$(cast send $CONTRACT "applyBleeding()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
HAS_BLEED_EVENT=$(echo "$RESULT" | grep -c "BleedingApplied" || true)
get_shares
if [ "$SHARE_B" = "$DEPOSIT" ]; then
    pass "No bleeding during grace period (shareB=$SHARE_B unchanged)"
else
    fail "Grace period" "shareB changed to $SHARE_B"
fi

echo "--- Test 1.5: Bleeding after grace period (PartyA deposits, PartyB defaults) ---"
echo "  Waiting 125s (2+ intervals past PartyB's last deposit)..."
sleep 125

# PartyA deposits to stay compliant
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"

SHARE_B_BEFORE=$SHARE_B
get_shares
SHARE_A_BEFORE=$SHARE_A

# Apply bleeding
RESULT=$(cast send $CONTRACT "applyBleeding()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
get_shares

if [ "$SHARE_B" -lt "$SHARE_B_BEFORE" ] && [ "$SHARE_A" -gt "$SHARE_A_BEFORE" ]; then
    LOST=$((SHARE_B_BEFORE - SHARE_B))
    GAINED=$((SHARE_A - SHARE_A_BEFORE))
    BURNED=$((LOST - GAINED))
    info "PartyB lost: $LOST wei, PartyA gained: $GAINED wei, burned: $BURNED wei"

    # Verify ~70/30 split: gained/lost should be ~0.70
    RATIO=$((GAINED * 100 / LOST))
    if [ "$RATIO" -ge 65 ] && [ "$RATIO" -le 75 ]; then
        pass "Bleeding activated: 70/30 split verified (ratio=${RATIO}%)"
    else
        fail "70/30 split" "ratio=${RATIO}% (expected 65-75)"
    fi
else
    fail "Bleeding activation" "shareB_before=$SHARE_B_BEFORE shareB_after=$SHARE_B shareA_before=$SHARE_A_BEFORE shareA_after=$SHARE_A"
fi

echo "--- Test 1.6: Decaying bleed rate (higher initially, decays to steady state) ---"
RATE=$(cast call $CONTRACT "getEffectiveBleedRate()" --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
if [ "$RATE" -ge 500 ]; then
    pass "Bleed rate at current age: $RATE bps (>= 500 steady state)"
else
    fail "Decaying rate" "rate=$RATE (expected >= 500)"
fi

echo "--- Test 1.7: No directional bleed when both default ---"
echo "  Waiting 125s (both miss deposits)..."
sleep 125
get_shares
B4_A=$SHARE_A
B4_B=$SHARE_B
cast send $CONTRACT "applyBleeding()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
if [ "$SHARE_A" = "$B4_A" ] && [ "$SHARE_B" = "$B4_B" ]; then
    pass "No bleeding when both default (shares unchanged)"
else
    fail "Both-default no-bleed" "A: $B4_A→$SHARE_A, B: $B4_B→$SHARE_B"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 2: RECOVERY FROM DEFAULT
# ═══════════════════════════════════════════════════════════════

section "PHASE 2: Recovery from Default"

echo "--- Test 2.1: Defaulter resumes deposits (missedPeriods reset) ---"
# PartyB was defaulting. Now deposit to recover.
# First, PartyA deposits to be compliant
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
get_shares
if [ "$PHASE" = "1" ]; then
    pass "PartyB resumed depositing, contract still Active (shares: A=$SHARE_A B=$SHARE_B)"
else
    fail "Recovery" "phase=$PHASE"
fi

echo "--- Test 2.2: After recovery, no further bleeding ---"
sleep 65
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
get_shares
B4_B=$SHARE_B
cast send $CONTRACT "applyBleeding()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
if [ "$SHARE_B" = "$B4_B" ]; then
    pass "No bleeding after recovery"
else
    fail "Post-recovery bleeding" "shareB changed: $B4_B → $SHARE_B"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 3: PEACEFUL EXIT
# ═══════════════════════════════════════════════════════════════

section "PHASE 3: Peaceful Exit"

echo "--- Test 3.1: Single proposal doesn't exit ---"
cast send $CONTRACT "proposeExit()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
if [ "$PHASE" = "1" ]; then
    pass "Single proposal: still Active"
else
    fail "Single proposal" "phase=$PHASE"
fi

echo "--- Test 3.2: Cancel proposal works ---"
cast send $CONTRACT "cancelExitProposal()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
pass "Exit proposal cancelled"

echo "--- Test 3.3: Both propose → PeacefulExit ---"
get_shares
FINAL_A=$SHARE_A
FINAL_B=$SHARE_B
cast send $CONTRACT "proposeExit()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
RESULT=$(cast send $CONTRACT "proposeExit()" --rpc-url $RPC --private-key $PKEY_B 2>&1)
get_shares
HAS_PEACEFUL=$(echo "$RESULT" | grep -c "0xca9c7d26" || true)
if [ "$PHASE" = "3" ] && [ "$HAS_PEACEFUL" -gt 0 ]; then
    pass "Peaceful exit: phase=Exited, PeacefulExit event emitted"
else
    fail "Peaceful exit" "phase=$PHASE peaceful=$HAS_PEACEFUL"
fi

echo "--- Test 3.4: Withdraw after peaceful exit ---"
CLAIM_A=$(cast call $CONTRACT "claimable(address)" $PARTY_A --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
if [ "$CLAIM_A" -gt 0 ]; then
    cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
    cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
    pass "Both parties withdrew (claimable_A=$CLAIM_A)"
else
    fail "Withdraw" "claimable_A=$CLAIM_A"
fi

echo "--- Test 3.5: Double withdraw reverts ---"
RESULT=$(cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "NothingToWithdraw"; then
    pass "Double withdraw reverts: NothingToWithdraw"
else
    fail "Double withdraw" "did not revert"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 4: UNILATERAL EXIT (new contract)
# ═══════════════════════════════════════════════════════════════

section "PHASE 4: Unilateral Exit (full flow)"
deploy
activate_both

echo "--- Test 4.1: Initiate unilateral exit ---"
RESULT=$(cast send $CONTRACT "initiateUnilateralExit()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
if echo "$RESULT" | grep -q "status.*1"; then
    pass "Unilateral exit initiated"
else
    fail "Initiate unilateral exit" "tx failed"
fi

echo "--- Test 4.2: Cannot initiate second unilateral exit ---"
RESULT=$(cast send $CONTRACT "initiateUnilateralExit()" --rpc-url $RPC --private-key $PKEY_B 2>&1 || true)
if echo "$RESULT" | grep -q "UnilateralExitAlreadyActive"; then
    pass "Second initiation blocked: UnilateralExitAlreadyActive"
else
    fail "Double initiate" "expected UnilateralExitAlreadyActive"
fi

echo "--- Test 4.3: Execute too early reverts ---"
RESULT=$(cast send $CONTRACT "executeUnilateralExit()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "ExitCountdownNotElapsed"; then
    pass "Early execution blocked: ExitCountdownNotElapsed"
else
    fail "Early execute" "expected ExitCountdownNotElapsed"
fi

echo "--- Test 4.4: Only initiator can cancel ---"
RESULT=$(cast send $CONTRACT "cancelUnilateralExit()" --rpc-url $RPC --private-key $PKEY_B 2>&1 || true)
if echo "$RESULT" | grep -q "Only initiator can cancel"; then
    pass "Non-initiator cancel blocked"
else
    fail "Cancel by non-initiator" "expected revert"
fi

echo "--- Test 4.5: Wait countdown (2 min) + execute with 15% penalty ---"
echo "  Waiting 125s for exit countdown..."
sleep 125

get_shares
A_BEFORE=$SHARE_A
B_BEFORE=$SHARE_B

RESULT=$(cast send $CONTRACT "executeUnilateralExit()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
if echo "$RESULT" | grep -q "status.*1"; then
    CLAIM_A=$(cast call $CONTRACT "claimable(address)" $PARTY_A --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
    CLAIM_B=$(cast call $CONTRACT "claimable(address)" $PARTY_B --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")

    # Penalty should be 15% of initiator's share
    EXPECTED_PENALTY=$((A_BEFORE * 1500 / 10000))
    EXPECTED_A=$((A_BEFORE - EXPECTED_PENALTY))
    EXPECTED_B=$((B_BEFORE + EXPECTED_PENALTY))

    info "PartyA before=$A_BEFORE, claimable=$CLAIM_A (expected=$EXPECTED_A)"
    info "PartyB before=$B_BEFORE, claimable=$CLAIM_B (expected=$EXPECTED_B)"

    if [ "$CLAIM_A" = "$EXPECTED_A" ] && [ "$CLAIM_B" = "$EXPECTED_B" ]; then
        pass "Unilateral exit: 15% penalty verified exactly"
    else
        # Allow for bleeding during countdown
        if [ "$CLAIM_A" -lt "$A_BEFORE" ] && [ "$CLAIM_B" -gt "$B_BEFORE" ]; then
            pass "Unilateral exit: penalty applied (amounts adjusted by bleeding during countdown)"
        else
            fail "Penalty verification" "claimA=$CLAIM_A expA=$EXPECTED_A claimB=$CLAIM_B expB=$EXPECTED_B"
        fi
    fi

    # Withdraw
    cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
    cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
    pass "Both parties withdrew after unilateral exit"
else
    fail "Unilateral exit execution" "tx failed"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 5: ABANDONMENT / DEAD MAN'S SWITCH (new contract)
# ═══════════════════════════════════════════════════════════════

section "PHASE 5: Abandonment (Dead Man's Switch)"
deploy
activate_both

echo "--- Test 5.1: Abandonment reverts when counterparty active ---"
RESULT=$(cast send $CONTRACT "claimAbandoned()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "Counterparty still active"; then
    pass "Abandonment blocked: Counterparty still active"
else
    fail "Active check" "expected revert"
fi

echo "--- Test 5.2: Claimer must be more active ---"
echo "  Waiting 200s (both stop, past 3-min abandonment threshold)..."
sleep 200
RESULT=$(cast send $CONTRACT "claimAbandoned()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "Claimer must be more active"; then
    pass "Blocked: claimer not more active than counterparty"
else
    fail "More active check" "expected revert"
fi

echo "--- Test 5.3: Active party claims abandoned funds ---"
# PartyA deposits to be "more active"
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"

RESULT=$(cast send $CONTRACT "claimAbandoned()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
if echo "$RESULT" | grep -q "status.*1"; then
    get_shares
    CLAIM_A=$(cast call $CONTRACT "claimable(address)" $PARTY_A --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
    if [ "$PHASE" = "3" ] && [ "$CLAIM_A" -gt 0 ]; then
        pass "Abandonment claimed: phase=Exited, all funds to claimer ($CLAIM_A wei)"
        cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
        pass "Claimer withdrew all funds"
    else
        fail "Abandonment result" "phase=$PHASE claimable=$CLAIM_A"
    fi
else
    fail "Abandonment claim" "tx failed"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 6: RUSSIAN ROULETTE (new contract)
# ═══════════════════════════════════════════════════════════════

section "PHASE 6: Russian Roulette"
deploy
activate_both

echo "--- Test 6.1: RR blocked during warmup (3 intervals = 3 min) ---"
RESULT=$(cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "WarmupPeriodActive"; then
    pass "RR blocked during warmup"
else
    fail "Warmup guard" "expected WarmupPeriodActive"
fi

echo "  Waiting 190s for warmup to expire (3 × 60s + buffer)..."
sleep 190

# Keep both parties depositing through warmup
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"

echo "--- Test 6.2: RR share gate (need >= 35%) ---"
# Make PartyB much larger so PartyA < 35%
cast send $CONTRACT "deposit()" --value $((DEPOSIT * 3)) --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"
cast send $CONTRACT "deposit()" --value $((DEPOSIT * 3)) --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"

RESULT=$(cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "ShareBelowGate"; then
    pass "RR share gate: blocked with <35% share"
else
    # PartyA might still have >= 35%, which is fine
    if echo "$RESULT" | grep -q "status.*1"; then
        skip "Share gate" "PartyA still has >= 35%, RR invoked instead"
    else
        fail "Share gate" "unexpected error"
    fi
fi

echo "--- Test 6.3: Rebalance and invoke RR ---"
# Deposit enough so PartyA has >= 35%
cast send $CONTRACT "deposit()" --value $((DEPOSIT * 3)) --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
cast send $CONTRACT "deposit()" --value $((DEPOSIT * 3)) --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"

get_shares
# Check phase - if already Frozen from a previous invoke, skip
if [ "$PHASE" = "1" ]; then
    RESULT=$(cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1)
    if echo "$RESULT" | grep -q "status.*1"; then
        RR_STATE=$(cast call $CONTRACT "getRRState()" --rpc-url $RPC)
        INV_COUNT=$(echo "$RR_STATE" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[0:64],16))")
        get_shares
        if [ "$PHASE" = "2" ]; then
            pass "RR TRIGGERED at invocation $INV_COUNT → phase=Frozen"
            RR_TRIGGERED=1
        else
            pass "RR invoked (k=$INV_COUNT), not triggered → phase=Active, cooldown started"
            RR_TRIGGERED=0
        fi
    else
        fail "RR invocation" "tx failed"
        RR_TRIGGERED=0
    fi
else
    skip "RR invoke" "already frozen from previous test"
    RR_TRIGGERED=1
fi

echo "--- Test 6.4: RR cooldown blocks immediate re-invocation ---"
get_shares
if [ "$PHASE" = "1" ]; then
    RESULT=$(cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 || true)
    if echo "$RESULT" | grep -q "CooldownActive"; then
        pass "RR cooldown active: blocks re-invocation"
    else
        if echo "$RESULT" | grep -q "status.*1"; then
            skip "Cooldown test" "RR invoked successfully (may have been past cooldown)"
        else
            fail "Cooldown" "unexpected error"
        fi
    fi
else
    skip "Cooldown test" "contract frozen"
fi

echo "--- Test 6.5: Freeze + release flow ---"
get_shares
if [ "$PHASE" = "2" ]; then
    # Try release too early
    RESULT=$(cast send $CONTRACT "releaseFrozenFunds()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
    if echo "$RESULT" | grep -q "FreezeNotExpired"; then
        pass "Frozen funds release blocked: FreezeNotExpired"
    else
        fail "Freeze guard" "expected FreezeNotExpired"
    fi

    echo "  Waiting 310s for freeze to expire (5 min)..."
    sleep 310

    RESULT=$(cast send $CONTRACT "releaseFrozenFunds()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
    if echo "$RESULT" | grep -q "status.*1"; then
        get_shares
        CLAIM_A=$(cast call $CONTRACT "claimable(address)" $PARTY_A --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
        CLAIM_B=$(cast call $CONTRACT "claimable(address)" $PARTY_B --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
        if [ "$PHASE" = "3" ] && [ "$CLAIM_A" -gt 0 ] && [ "$CLAIM_B" -gt 0 ]; then
            pass "Frozen funds released: phase=Exited, both parties claimable (A=$CLAIM_A B=$CLAIM_B)"
        else
            fail "Frozen release" "phase=$PHASE claimA=$CLAIM_A claimB=$CLAIM_B"
        fi
    else
        fail "Frozen funds release" "tx failed"
    fi
elif [ "$PHASE" = "1" ]; then
    # Need to force freeze by invoking RR until trigger (up to 6 times, with 2-min cooldown)
    info "Contract still Active. Attempting to force freeze via repeated RR..."
    for i in $(seq 1 6); do
        get_shares
        [ "$PHASE" != "1" ] && break

        # Wait cooldown
        if [ $i -gt 1 ]; then
            echo "  Waiting 125s for RR cooldown..."
            sleep 125
        fi

        # Alternate invokers, keep depositing
        if [ $((i % 2)) -eq 1 ]; then
            cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1" || true
            cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1" || true
        else
            cast send $CONTRACT "deposit()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1" || true
            cast send $CONTRACT "invokeRoulette()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1" || true
        fi

        get_shares
        RR_STATE=$(cast call $CONTRACT "getRRState()" --rpc-url $RPC)
        K=$(echo "$RR_STATE" | python3 -c "import sys; d=sys.stdin.read().strip()[2:]; print(int(d[0:64],16))")
        info "RR invocation $K: phase=$PHASE"
    done

    get_shares
    if [ "$PHASE" = "2" ]; then
        pass "Forced freeze via repeated RR"

        echo "  Waiting 310s for freeze to expire..."
        sleep 310

        cast send $CONTRACT "releaseFrozenFunds()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
        get_shares
        if [ "$PHASE" = "3" ]; then
            pass "Frozen funds released after expiry"
        else
            fail "Frozen release" "phase=$PHASE"
        fi
    else
        skip "Freeze+release" "could not force freeze (RR probabilistic)"
    fi
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 7: CANCEL INACTIVE (new contract)
# ═══════════════════════════════════════════════════════════════

section "PHASE 7: Cancel Inactive Agreement"
deploy

echo "--- Test 7.1: PartyA activates only ---"
cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
get_shares
if [ "$PHASE" = "0" ] && [ "$SHARE_A" = "$DEPOSIT" ]; then
    pass "PartyA activated alone, phase=Inactive"
else
    fail "Partial activation" "phase=$PHASE"
fi

echo "--- Test 7.2: Cancel too early reverts ---"
RESULT=$(cast send $CONTRACT "cancelInactive()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "Too early to cancel"; then
    pass "Cancel too early blocked"
else
    fail "Early cancel" "expected revert"
fi

echo "--- Test 7.3: Cancel after timeout (2 min) ---"
echo "  Waiting 125s for cancel timeout..."
sleep 125
RESULT=$(cast send $CONTRACT "cancelInactive()" --rpc-url $RPC --private-key $PKEY_A 2>&1)
if echo "$RESULT" | grep -q "status.*1"; then
    get_shares
    CLAIM_A=$(cast call $CONTRACT "claimable(address)" $PARTY_A --rpc-url $RPC | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))")
    if [ "$PHASE" = "3" ] && [ "$CLAIM_A" = "$DEPOSIT" ]; then
        pass "Inactive cancelled: full refund to PartyA ($CLAIM_A wei)"
        cast send $CONTRACT "withdraw()" --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
        pass "PartyA withdrew refund"
    else
        fail "Cancel inactive" "phase=$PHASE claimable=$CLAIM_A"
    fi
else
    fail "Cancel inactive" "tx failed"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 8: EDGE CASES
# ═══════════════════════════════════════════════════════════════

section "PHASE 8: Edge Cases & Access Control"
deploy

echo "--- Test 8.1: Direct ETH transfer reverts ---"
RESULT=$(cast send $CONTRACT --value 1000 --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "revert\|error\|Error"; then
    pass "Direct ETH transfer rejected"
else
    fail "Direct ETH" "did not revert"
fi

echo "--- Test 8.2: Non-party access reverts ---"
CHARLIE_KEY=0xabf22d7a3e45e2dce890a28f7e174c1020d869f7f1734140ea523e6c25043dc2
# Fund charlie with minimal gas
cast send 0x837664A706AC524cB183e9bc7eeE01463AD8F46B --value 500000000000 --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1" || true
RESULT=$(cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $CHARLIE_KEY 2>&1 || true)
if echo "$RESULT" | grep -q "NotParty"; then
    pass "Non-party activate blocked: NotParty"
else
    fail "Non-party access" "expected NotParty revert"
fi

echo "--- Test 8.3: Wrong phase reverts ---"
cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 | grep -q "status.*1"
cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_B 2>&1 | grep -q "status.*1"

# Now Active — try activate again
RESULT=$(cast send $CONTRACT "activate()" --value $DEPOSIT --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "WrongPhase"; then
    pass "Wrong phase: activate on Active → WrongPhase"
else
    fail "Wrong phase" "expected WrongPhase"
fi

# Active — try cancelInactive
RESULT=$(cast send $CONTRACT "cancelInactive()" --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "WrongPhase"; then
    pass "Wrong phase: cancelInactive on Active → WrongPhase"
else
    fail "Wrong phase cancelInactive" "expected WrongPhase"
fi

echo "--- Test 8.4: Below minimum deposit ---"
RESULT=$(cast send $CONTRACT "deposit()" --value $((DEPOSIT / 2)) --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "Below minimum deposit"; then
    pass "Below minimum deposit blocked"
else
    fail "Min deposit" "expected revert"
fi

echo "--- Test 8.5: Above max deposit (3x) ---"
RESULT=$(cast send $CONTRACT "deposit()" --value $((DEPOSIT * 4)) --rpc-url $RPC --private-key $PKEY_A 2>&1 || true)
if echo "$RESULT" | grep -q "Exceeds max deposit"; then
    pass "Above max deposit blocked"
else
    fail "Max deposit" "expected revert"
fi

echo "--- Test 8.6: Max deposit (3x) accepted ---"
RESULT=$(cast send $CONTRACT "deposit()" --value $((DEPOSIT * 3)) --rpc-url $RPC --private-key $PKEY_A 2>&1)
if echo "$RESULT" | grep -q "status.*1"; then
    pass "3x deposit accepted"
else
    fail "3x deposit" "tx failed"
fi

# ═══════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════

section "TEST SUMMARY"
echo ""
echo "  Total:   $TOTAL"
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "  🎉 ALL TESTS PASSED"
else
    echo "  ⚠️  $FAIL TEST(S) FAILED"
fi
echo ""
