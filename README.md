# MLL Protocol

**Mutual Liquidity Lock** — a bilateral commitment device implemented as an Ethereum smart contract.

Two parties lock capital into a shared pool with periodic heartbeat deposits. Defection (stopping deposits) triggers automatic bleeding penalties. The protocol makes cooperation self-reinforcing: every deposit raises the cost of future defection, creating an equilibrium that strengthens over time.

## Mechanisms

**Heartbeat Deposits** — Both parties deposit a fixed amount at regular intervals. Silence is defection.

**Bleeding Penalty** — When one party stops depositing past the grace period, their share drains: 70% to the counterparty, 30% permanently burned. The 70/30 split prevents the punisher from becoming a rentier while maintaining self-enforcement incentives.

**Russian Roulette** — Either party can trigger a graduated destruction mechanism with escalating probability (1/6 → 1/5 → ... → 1/1). If triggered, the entire pool freezes for ~10 years. This is [Schelling's brinkmanship](https://en.wikipedia.org/wiki/Brinkmanship) in code — the risk drives both parties toward negotiated exit.

**Exit Paths:**

| Path | Condition | Outcome |
|------|-----------|---------|
| Peaceful | Both agree | Each gets their share |
| Unilateral | 30-day countdown | Initiator pays 15% penalty |
| Freeze | Roulette triggered | Funds locked ~10 years |
| Abandonment | Counterparty inactive past `max(90 days, 3·depositInterval)` with strictly older last deposit | Active party claims all |

## Key Properties

- **Self-reinforcing**: cooperation threshold δ* decreases as pool grows — see [blog](https://argus.101001.org/mutual-liquidity-lock.html) for formal derivation (note: published δ* table assumes G=0; with default `gracePeriods=1`, the binding constraint is `δ ≥ [d/(d+Rs)]^{1/(G+1)}`, raising thresholds by 6–24 pp)
- **Pull-based withdrawals**: all exit paths credit a `claimable` mapping — prevents DoS
- **Cold-start decay**: initial bleed rate starts at 2x and linearly decays over 6 periods

## Contracts

| Contract | Lines | Description |
|----------|-------|-------------|
| `MutualLiquidityLock.sol` | 591 | Core protocol — deposits, bleeding, exit paths, abandonment |
| `RussianRoulette.sol` | 136 | RR module — graduated destruction with cooldown and safeguards |
| `MutualLiquidityLockTestable.sol` | 561 | Testable variant with shortened time constants (minutes vs days) |
| `RussianRouletteTestable.sol` | 96 | Testable RR with 2-minute cooldown |

## Deployment

Production contract on **Base** (Ethereum L2), verified on [Sourcify](https://sourcify.dev):

```
0x9FB1e49a09572C10439Dc79CFEbFadb0441D7E7B
```

[View on Basescan](https://basescan.org/address/0x9FB1e49a09572C10439Dc79CFEbFadb0441D7E7B#code)

Compiled with solc 0.8.33, `via_ir` optimization, 200 runs.

> **Note**: The deployed contract predates a minor bugfix in this repository. The on-chain version sets `lastBleedApplied = block.timestamp` which loses sub-day fractional bleed time (~1.6–3% annual impact). The repository source uses the corrected `lastBleedApplied = bleedStart + newBleedDays * 1 days`, snapping to the last fully-processed day boundary. This is the only difference between deployed and source.

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
cd contracts
forge install
forge build
forge test
```

35/35 tests passing. Full coverage of: activation, deposits, bleeding (70/30 split, decay, grace period, both-default), peaceful exit, unilateral exit (countdown, penalty, cancellation), abandonment, Russian Roulette (warmup, share gate, cooldown, k=6 certain trigger), freeze/release, withdrawal, and pool balance invariant.

On-chain integration testing was also completed on Base mainnet across 4 separate contract deployments, covering all mechanisms end-to-end including the full RR escalation sequence (k=1 through k=6 trigger → freeze → release).

### Deploy

```bash
cd contracts
PARTY_B=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

Set `TESTNET=false` for production parameters (30-day intervals, 0.1 ETH deposits).

## Known Limitations

- **Pseudo-random RR**: uses `block.prevrandao` — manipulable by validators, especially on L2s with single sequencers. Production deployment requires Chainlink VRF or equivalent.
- **RR callable during unilateral exit**: the 30-day exit countdown runs in `Active` phase, during which Russian Roulette remains invocable (up to 3 times with 10-day cooldowns, cumulative ~50% freeze probability). Unilateral exit is a penalty-based escape, not a guaranteed safety valve.
- **Per-tx deposit cap**: the 3x cap is per-transaction, not per-interval. A party can make multiple deposits within one interval.
- **Uncapped activation deposit**: `activate()` requires `msg.value >= depositAmount` with no upper bound, allowing asymmetric initial stakes.
- **Cold-start fragility**: the protocol cannot bootstrap itself — initial cooperation requires external trust or incentive.

## Documentation

- [Blog Post (English / Chinese)](https://argus.101001.org/mutual-liquidity-lock.html)

## License

MIT
