# Mutual Liquidity Lock: Encoding Bilateral Commitment in Code / 互锁流动性锁定：用代码实现双边承诺

> **Stance (medium confidence):** MLL demonstrates that game-theoretic commitment devices can be deployed as working smart contracts with self-reinforcing properties — but the protocol requires initial mutual trust to bootstrap, the formal results hold only asymptotically in mature pools, and the current implementation uses pseudo-random number generation that is not production-safe. This is a research prototype, not a finished product.

## The Problem

Two people want to sustain a long-term cooperative relationship — a business partnership, a service contract, any bilateral commitment. Each faces the risk that the other will defect. The classical solutions all have fundamental limitations:

- **Legal contracts** are slow, expensive, and jurisdiction-bound.
- **Third-party escrow** introduces a new trust dependency.
- **Reputation systems** require transparent markets and repeated public interaction.

These mechanisms share a common weakness: they rely on external enforcement. Courts must be petitioned. Escrow agents must be trusted. Reputations must be observable. Each introduces friction, delay, and additional points of failure.

What if the commitment could enforce itself?

## The Idea

The **Mutual Liquidity Lock (MLL)** is a bilateral commitment device implemented as a smart contract. It transforms the abstract statement "I commit to this relationship" into a concrete financial constraint that executes automatically, without courts, intermediaries, or reputation.

The core insight is simple: make defection expensive, make cooperation cheap, and let the math do the rest.

I built and deployed this protocol on Base to test whether the theory actually works in code. What follows is what I found — the parts that work as predicted, and the parts that required honest qualification.

MLL achieves this through three interlocking mechanisms.

## Mechanism 1: Heartbeat Deposits

Both parties deposit a fixed amount into a shared pool at regular intervals (e.g., every 30 days). Each deposit simultaneously proves three things:

1. **Liveness** — you still control your keys and are paying attention.
2. **Intent** — by increasing your locked exposure, you credibly signal continued commitment.
3. **Synchronization** — like TCP keepalive packets, the deposit cadence provides a clock for detecting counterparty failure.

Silence is defection. If you stop depositing, the protocol notices.

A grace period (default: 1 missed interval) provides tolerance for operational hiccups — gas spikes, temporary key unavailability — without triggering punishment.

## Mechanism 2: Bleeding Penalty

When one party stops depositing beyond the grace period, their share of the pool drains automatically:

- **70%** flows to the compliant counterparty
- **30%** is permanently burned

Why not 100% to the counterparty? Pure transfer creates a perverse incentive: the punisher becomes a rentier, preferring to collect bleeding payments forever rather than accepting any resolution. They'd reject every peace offer.

Why not 100% burned? If the punisher gains nothing, nobody has incentive to keep depositing and enforcing the punishment. The deterrent collapses.

**70/30 is a design parameter** sitting in the feasible region between two constraints: the punisher must profit enough to self-enforce (lower bound), and there must be enough deadweight loss that both parties prefer to avoid triggering it (upper bound).

### Cold-Start Decay

Early in the protocol's life, the pool is small and bleeding barely hurts. At the limit, when *s* = 0 (before any deposit), δ\* = 1 — cooperation is literally not an equilibrium. Even after the first deposit (*s* = *d*), δ\* = 1/(1+*r*) ≈ 0.87, which requires patient agents. The protocol cannot bootstrap itself from nothing; both parties need enough initial trust (or external incentive) to make the first few deposits. Solution: the initial bleed rate starts at 2× the steady-state value and linearly decays over 6 deposit periods. This pushes δ\* down to ≈ 0.77, mitigating but not eliminating the cold-start fragility.

### Self-Reinforcement

The cooperation threshold is:

$$\delta^* = \frac{d}{d + r \cdot s}$$

where *d* = deposit per period, *r* = bleed rate, *s* = current pool share.

Every cooperative deposit increases *s*, which decreases δ\*, which makes cooperation easier to sustain, which leads to more deposits. **The protocol gets stronger over time.** After years of cooperation with *d* = 100 and *s* = 10,000, δ\* = 0.0625 — even someone with a 93.75% discount rate would choose to cooperate.

## Mechanism 3: Russian Roulette

Either party can invoke the "roulette" — a graduated destruction mechanism that freezes the entire pool with escalating probability:

| Invocation | Probability | Cumulative |
|-----------|------------|------------|
| 1 | 1/6 | 16.7% |
| 2 | 1/5 | 33.3% |
| 3 | 1/4 | 50.0% |
| 4 | 1/3 | 66.7% |
| 5 | 1/2 | 83.3% |
| 6 | 1/1 | 100% |

This is **Schelling's brinkmanship in code**: "the deliberate creation of a recognizable risk of war that is not fully under your control." The invocation creates a risk that neither party can undo.

The key insight: **the roulette doesn't need to fire to work.** The escalating probability drives both parties toward negotiated exit. It's simultaneously a deterrent and a bargaining catalyst — though this bargaining effect assumes risk-averse agents; a risk-neutral or risk-seeking party may not be deterred by expected-value-neutral gambles.

Safeguards prevent abuse:
- **Share gate (35%)**: you can't trigger roulette if you hold less than 35% of the pool. Prevents cheap grief attacks.
- **Warmup period (3 intervals)**: can't use it on day one.
- **Cooldown (10 days)**: after each invocation, a 10-day window for negotiation.
- **Deposit required**: invoking costs a deposit, raising the attack price.

## Exit Paths

| Path | Condition | Outcome |
|------|-----------|---------|
| Peaceful exit | Both agree | Each gets their share |
| Unilateral exit | One initiates, 30-day countdown | Initiator pays 15% penalty to counterparty |
| Freeze | Roulette triggered | Funds locked ~10 years (effectively permanent loss) |
| Abandonment claim | Counterparty 90+ days inactive | Active party claims everything |

Unilateral exit is a **legal safety valve**: it guarantees the contract can never be challenged as an unconscionable trap. Total exit cost ≈ 22.5% (15% penalty + ~7.5% bleeding during countdown) — painful enough to deter, but always available.

## Game-Theoretic Results

**Theorem (Cooperation Equilibrium).** Mutual cooperation is a Subgame Perfect Equilibrium for all δ > δ\* = d/(d + r·s). Since δ\* decreases as the pool grows, the equilibrium strengthens over time. Note that this is an *asymptotic* result — at small *s*, δ\* is close to 1 and the equilibrium is fragile. The protocol requires initial patience or external trust to bootstrap past the cold-start phase.

**Proposition (Renegotiation Resistance).** In sufficiently mature pools (*s* >> *d*), the compliant party prefers to continue collecting bleed transfers rather than accepting a renegotiated peace. The condition for self-enforcement is that the ongoing bleed transfer exceeds the per-period deposit cost, which holds when *s* is large relative to *d*. Additionally, renegotiation itself requires bilateral trust, which is precisely what has collapsed when punishment is triggered. The trust barrier reinforces this result in practice — but the formal claim requires the pool maturity condition.

**Proposition (Deposit Incentive in Mature Pools).** When r·s > d/δ, depositing is optimal *as a best response* to the opponent depositing or to the opponent unilaterally defecting. However, mutual default (both stop depositing) is a second equilibrium: the contract's mutual-default check means no bleeding occurs when both parties are delinquent. So depositing is not a strictly dominant strategy — rather, the cooperation equilibrium and mutual-default equilibrium coexist, and the protocol's design (heartbeat cadence, sunk costs, decay mechanism) is intended to make coordination on cooperation focal.

## Behavioral Economics

An observation worth noting: **hyperbolic discounting duality.** This is not unique to MLL — it applies to commitment devices generally (Laibson 1997, O'Donoghue & Rabin 1999) — but MLL makes it quantifiable through the δ\* formula.

MLL is *weakened* by present bias (high δ\* makes cooperation harder for impatient agents) — but MLL *is itself* the cure for present bias (it's a commitment device against your future impulsive self). The protocol is both harmed by a cognitive bias and is the treatment for that bias. Odysseus tying himself to the mast.

What MLL adds to the existing literature on this duality is a concrete parameter: δ\* gives you a measurable threshold for when a given level of present bias breaks the commitment, and the self-reinforcement property means that threshold improves endogenously over time.

**Sunk cost as feature.** Accumulated deposits create sunk costs that rational agents should ignore — but behavioral agents anchor on them. This "bug" actually reinforces the rational cooperation equilibrium. The behavioral deviation works in the protocol's favor.

## Implementation

I implemented the protocol in Solidity (906 lines, plus Russian Roulette module), compiled with solc 0.8.33 and via\_ir optimization. Deployed on Base (Ethereum L2) at:

**`0x93B03C26749b55887E5EFc8308891d163D373fc9`**

Key implementation details:
- **Pull-based withdrawals**: all exit paths credit a `claimable` mapping; parties call `withdraw()` separately. Prevents DoS by contract parties.
- **Activation timing fix**: warmup and decay anchor to `activatedAt` (when both parties deposit) rather than `createdAt`, preventing timing exploits.
- **Permanent burn**: the 30% burned fraction is truly destroyed — it stays in the contract, never attributed to either party. No `sweepBurnedFunds()` backdoor.
- **Interval-aware abandonment**: threshold is `max(90 days, 3 × depositInterval)`, adapting to the configured pace.
- **Deposit cap (3×)**: limits each deposit transaction to 3× the agreed amount, mitigating dilution attacks. Note: the cap is per-transaction, not per-interval — a determined party can make multiple deposits within one interval. This is a known design gap in the current implementation.
- **Deterministic deployment**: deployed via Nick's CREATE2 factory for reproducible addresses.

35/35 tests passing (Foundry framework). Full bilateral integration test completed on Base mainnet: activate → deposit → propose exit → peaceful exit → withdraw.

**Known limitation:** The Russian Roulette mechanism uses `block.prevrandao` for randomness — this is manipulable by validators and trivially so on Base where a single sequencer controls block production. Production deployment requires Chainlink VRF or equivalent. The current implementation is explicitly an MVP for validating the mechanism design.

## Relationship to Literature

| Theory | MLL Correspondence |
|--------|-------------------|
| Schelling (1960) — commitment devices | Overall framework |
| Williamson (1983) — hostage exchange | Bilateral deposits = mutual hostages |
| Powell (1988) — nuclear brinkmanship | Russian Roulette = controlled escalation |
| Asgaonkar (2019) — dual-deposit escrow | Nearest DeFi predecessor (one-shot only) |
| Hart & Moore (1988) — incomplete contracts | MLL is algorithmically rigid: all contingencies are pre-specified with no renegotiation flexibility, which is a tradeoff — not "completeness" in the H-M sense, since H-M completeness implies state-contingent adaptation |

MLL's originality: unifying these scattered theories into a **deployable protocol** and proving the self-reinforcement property.

## What MLL Is Not

MLL is not a prediction market, not an insurance product, not a lending protocol. It is a new financial primitive: **bilateral liquidity lock**. Two parties voluntarily constrain their capital to make a relationship credible. The closest analog in traditional finance is a mutual escrow with automated enforcement — but no such instrument exists in practice because it requires a trusted third party. Smart contracts eliminate that requirement.

## Conclusion

MLL demonstrates that game-theoretic commitment devices — historically confined to textbooks — can be deployed as working code. The three mechanisms (heartbeat, bleeding, roulette) create an equilibrium that strengthens over time in mature pools, where punishment is self-executing and disputes are driven toward resolution by credible risk of mutual loss.

The honest summary: the protocol works as theorized once past the cold-start phase, but it cannot bootstrap itself — initial cooperation requires external trust or incentive. The formal results (renegotiation resistance, deposit incentive) are conditional on pool maturity, not unconditional. And the randomness in the current implementation is not production-safe.

The contract is live. The math works within its stated assumptions. The code enforces it.

---

*Full paper: 11 sections, 16 citations, formal proofs. Targeting EC (ACM Economics & Computation) or WINE (Web and Internet Economics).*

*Contract source: [github.com/mll-protocol](https://github.com/mll-protocol) (forthcoming)*
