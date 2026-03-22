# MLL Protocol

**Mutual Liquidity Lock** — a bilateral commitment device implemented as an Ethereum smart contract.

Two parties lock capital into a shared pool with periodic heartbeat deposits. Defection (stopping deposits) triggers automatic bleeding penalties. The protocol makes cooperation self-reinforcing: every deposit raises the cost of future defection, creating an equilibrium that strengthens over time.

## Mechanisms

**Heartbeat Deposits** — Both parties deposit a fixed amount at regular intervals. Silence is defection.

**Bleeding Penalty** — When one party stops depositing past the grace period, their share drains — 100% transferred to the compliant counterparty. No value is burned; total pool is preserved. The compliant party has a direct incentive to continue depositing during counterparty default.

**Dynamic Exit Penalty** — Unilateral exit incurs a penalty that starts at 80% (cold start) and decays linearly to 15% as cumulative deposits reach the target maturity (default: 7 deposits). This solves the cold-start problem: early defectors pay a severe penalty; mature participants get a reasonable exit.

`penalty(S) = P_max − (P_max − P_min) · min(S / (n · d), 1)`

**Exit Paths:**

| Path | Condition | Outcome |
|------|-----------|---------|
| Peaceful | Both agree | Each gets their share |
| Unilateral | 30-day countdown | Initiator pays dynamic penalty (15%–80%) to counterparty |
| Abandonment | Counterparty inactive past `max(90 days, 3·depositInterval)` with strictly older last deposit | Active party claims all |

## Key Properties

- **Self-reinforcing**: cooperation threshold δ* decreases as pool grows — see [blog](https://argus.101001.org/mutual-liquidity-lock.html) for formal derivation
- **Dynamic exit penalty**: 80% → 15% based on cumulative deposits, solving cold-start directly
- **Pull-based withdrawals**: all exit paths credit a `claimable` mapping — prevents DoS
- **Mutual-default clock advancement**: prevents retroactive bleed when both parties default then one resumes
- **100% bleed transfer**: no burn, total pool value preserved through bleeding

## Contracts

| Contract | Lines | Description |
|----------|-------|-------------|
| `MutualLiquidityLock.sol` | ~480 | Core protocol — deposits, bleeding, dynamic penalty, exit paths, abandonment |
| `MutualLiquidityLockTestable.sol` | ~450 | Testable variant with shortened time constants (minutes vs days) |

## Deployment

Production contract on **Base** (Ethereum L2), verified on [Sourcify](https://sourcify.dev):

```
0xd25de1a0a1433ca3bad55ec3fb6b2488111649de
```

[View on Basescan](https://basescan.org/address/0xd25de1a0a1433ca3bad55ec3fb6b2488111649de#code)

Compiled with solc 0.8.33, `via_ir` optimization, 200 runs. Verified on Sourcify (exact match).

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
cd contracts
forge install
forge build
forge test
```

33/33 tests passing. Full coverage of: activation, deposits, bleeding (100% transfer, grace period, both-default-no-bleed, no retroactive bleed after mutual default), peaceful exit, unilateral exit (countdown, dynamic penalty at cold-start/midpoint/maturity/per-party, cancellation), abandonment (threshold, activity check, clearing pending exit), pool balance invariant, and withdrawal.

### Deploy

```bash
cd contracts
PARTY_B=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

Set `TESTNET=false` for production parameters (30-day intervals, 0.1 ETH deposits).

## Known Limitations

- **Per-tx deposit cap**: the 3x cap is per-transaction, not per-interval. A party can make multiple deposits within one interval.
- **Uncapped activation deposit**: `activate()` requires `msg.value >= depositAmount` with no upper bound, allowing asymmetric initial stakes.
- **Cold-start fragility**: the dynamic penalty significantly narrows the cold-start vulnerability but cannot eliminate it — initial cooperation still requires some external trust or incentive.

## Documentation

- [Blog Post (English / Chinese)](https://argus.101001.org/mutual-liquidity-lock.html)
- [Formal Model](model/formal-model.tex)

## License

MIT
