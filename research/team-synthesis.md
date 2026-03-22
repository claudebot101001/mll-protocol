# MLL Analysis Team — Synthesis of 4-Round Discussion

**Team**: Game Theorist + DeFi Architect + Behavioral Economist
**Rounds**: 4 (fully converged)
**Cost**: $3.12

---

## Converged Design Decisions

### 1. Grief Attack Mitigation (CRITICAL)

**Problem**: A party with negligible pool share can weaponize Russian Roulette to freeze a much larger counterparty's funds. Cost asymmetry makes this a viable griefing strategy.

**Solution (converged)**: Two-layer defense:
- **Share gate**: Minimum 35% pool share required to invoke RR. When share falls below this (due to bleeding), RR access is revoked. Self-limiting: by the time the asymmetry is exploitable, the griefer has lost RR access.
- **Warmup period**: First 3 deposit intervals (e.g., 90 days), no RR access. Prevents day-1 griefing.

**Alternative considered**: Deposit-to-invoke (must deposit d to trigger RR). Team converged that this adds UX friction without proportional security benefit when share gate is present. However, it provides marginal cost per invocation that strengthens deterrence — reasonable as defense-in-depth.

### 2. Bleed Destination: 70/30 Split

**Problem**: Pure counterparty-enrichment creates spite dynamics; pure burn breaks IC.

**Analysis**:
- **100% to counterparty**: Punisher actively benefits from punishment → self-enforcing BUT creates spite incentive (punisher may refuse reasonable exit offers).
- **100% burned**: Punisher gains nothing → indifferent between punishing and exiting → punishment collapses to ~1 period → deterrence destroyed.
- **70/30 split (70% counterparty, 30% burned)**: Punisher retains sufficient incentive to maintain punishment. Burned portion reduces spite motive. Parameter α (counterparty fraction) is tunable with derivable lower bound: α must make PV of bleed stream > opportunity cost of locked capital.

**Recommendation**: α = 0.70 as default. Configurable per agreement.

### 3. "Permanent" Freeze → Configurable Long Lock (Default 10 Years)

**Problem**: Permanent freeze is legally vulnerable in jurisdictions that recognize smart contract interactions as contractual.

**Solution**: Replace with configurable lock (default 10 years). At daily δ=0.995, PV of funds locked 10 years = principal × 0.995^3650 ≈ 0.0016% of principal — effectively zero. Deterrence identical. Legal exposure eliminated.

### 4. Unilateral Exit with Penalty

**Design**: Allow any party to initiate unilateral exit with:
- **Countdown period**: T = 30 days (configurable)
- **Exit penalty**: p = 15% of exiting party's share (forfeited to counterparty)
- **Bleeding continues during countdown**

**Total unilateral exit cost**: ~22.5% of share (15% penalty + ~7.5% bleed over 30 days). For mature pools where s >> d, this is a devastating cost that preserves deterrence while providing a legal escape valve.

**Why this is important**: Without unilateral exit, MLL could be challenged as an unconscionable contract (no way to leave). With it, the exit option is always available — just expensive.

### 5. Cold Start Problem

**Problem**: At pool inception, δ* ≈ 0.99 (daily) — cooperation equilibrium barely holds. Small external shock → defection.

**Solution (converged)**: Decaying bleeding rate.
- Start with r₀ = 2× steady-state rate during first 6 intervals
- Decay to steady-state r over next 6 intervals
- Simpler than bonding curve, equivalent effect

### 6. Renegotiation-Proofness

**Key finding**: MLL achieves *de facto* renegotiation-resistance through a trust barrier, not a formal property. The mechanism fails BPW renegotiation-proofness in theory, but renegotiation requires bilateral trust — exactly the trust that failed when punishment was triggered. "When the mechanism is most needed (low trust), renegotiation is least feasible."

**Paper framing**: "Renegotiation-resistant with deterministic punishment under on-chain enforcement; BPW-fails only via costly off-chain exit-and-reenter, which preserves deterrence magnitude."

### 7. Yield Integration

**Unanimous**: Defer to v2. Yield protocol composability adds attack surface that dwarfs the benefit. v1 ships with no yield.

---

## Key Behavioral Insights

1. **Loss aversion amplifies RR frequency beyond rational prediction**. Real humans trigger RR earlier than the model predicts because losses loom larger. The 10-day cooldown is more important than the probability sequence for preventing impulsive escalation.

2. **Hyperbolic discounting duality** (most publishable insight): MLL is simultaneously *weakened by* and *a solution to* present bias. Weakened: impatient agents have higher δ*, making cooperation harder. Solution: the protocol itself is a commitment device against present-biased future-selves. Novel framing worth formalizing.

3. **Sunk cost fallacy helps MLL**: People stay in relationships because they've "already invested so much." In MLL this behavioral bias reinforces the rational equilibrium — it's a bug that acts as a feature.

4. **Adverse selection concern**: Who opts into MLL? Self-selection may skew toward low-trust relationships that are already unstable. Counter-argument: couples therapy also selects on relationship trouble, and still helps.

---

## Formal Results to Prove

| # | Result | Status |
|---|--------|--------|
| 1 | Cooperation SPE existence (δ ≥ δ*) | Proven in formal model |
| 2 | δ* decreasing in pool size (maturity effect) | Proven (corollary) |
| 3 | Bleeding self-enforcement (punisher prefers continuing) | Proven when α > lower bound |
| 4 | RR as bargaining catalyst (risk-averse parties converge) | Proven (proposition) |
| 5 | Unilateral exit penalty preserves maturity property | Need to formalize |
| 6 | Share gate prevents profitable grief attack | Need to formalize |

---

## Implementation Changes from Team Discussion

Applied to Solidity MVP:
- [x] Warmup period (3 intervals, no RR)
- [x] RR requires deposit (defense-in-depth)
- [x] Dead man's switch: 90 days (was 180)
- [x] Share gate (35% minimum for RR access)
- [x] 70/30 bleed split
- [x] Unilateral exit with penalty
- [x] Configurable freeze duration (default 10 years)
- [x] Decaying bleeding rate for cold start
