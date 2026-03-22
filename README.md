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
| Abandonment | Counterparty 90+ days inactive | Active party claims all |

## Key Properties

- **Self-reinforcing**: cooperation threshold `delta* = d/(d + r*s)` decreases as pool grows
- **Renegotiation-resistant**: in mature pools, the compliant party prefers ongoing bleed transfers over any peace deal
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

Production contract on **Base** (Ethereum L2):

```
0x93B03C26749b55887E5EFc8308891d163D373fc9
```

Compiled with solc 0.8.33, `via_ir` optimization, 200 runs.

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

- **Pseudo-random RR**: uses `block.prevrandao` — manipulable by validators, especially on L2s with single sequencers. Production deployment requires Chainlink VRF.
- **Per-tx deposit cap**: the 3x cap is per-transaction, not per-interval. A party can make multiple deposits within one interval.
- **Cold-start fragility**: the protocol cannot bootstrap itself — initial cooperation requires external trust or incentive.

## Documentation

- [Blog Post (English)](docs/mll-blog-en.md)
- [Blog Post (Chinese)](docs/mll-blog-zh.md)

## License

MIT
