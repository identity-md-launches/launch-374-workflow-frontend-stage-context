# Receipt test extensions

The existing `LaunchFixture` deploys a real v4 `PoolManager`, mines and CREATE2-deploys the production hook, initializes the native ETH / RCPT pool, and seeds token-only liquidity. The first buy starts with no ETH in the manager. The rehearsal uses `script/LaunchConfig.sol`; this checkout has no `launch.json` to cross-check against those constants.

`SwapReceiptAdversarial.t.sol` extends the existing launch and hook suites with:

- Exact-out first buys settling exactly 0.001 ETH and one wei less, plus fuzzing around that boundary. The quote probe is reverted before each first buy. Receipt eligibility is checked against the actual payment after refunds, including exact-in / exact-out rounding differences.
- Partial exact-out fills, arbitrary hookData, and dirty upper address bits through the real manager.
- Both sell modes, contract recipients with missing or reverting receiver functions, and rollback of the receipt and pool state when an exact-out buy cannot settle.
- Fuzzed transfer and approval paths from owners and outsiders, pagination extremes, and base64 JSON fields checked against settlement and stored receipt data.
- A cold first-mint gas ceiling of 199,999 gas. This test captures the real manager's callback calldata, restores the pre-swap state, cools the hook, and replays only that callback while impersonating the manager. The production manager and hook bytecode are unchanged. The existing launch test can additionally be run with `-vvvv` to inspect gas for the actual nested callback.

`SwapReceiptInvariant.t.sol` runs 64 sequences of 64 handler actions with `fail-on-revert` enabled. It mixes exact-in and exact-out buys, sells, malformed identities, and attempted soulbound operations. Four initial buys ensure ownership checks include real receipts for EOAs and both kinds of contract recipient. Ghost receipt records come from settled ETH and token balance changes. Invariants check all historical records and owner indexes, conservation of tokens and ETH, zero open manager deltas, and no funds retained by the hook or router.

Run without writing build artifacts outside the test workspace:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache --match-test test_firstBuyOfOneThousandthEthMintsReceiptOne -vvvv
```

These tests need no RPC, environment mutation, downloaded dependency, or file from `test/scratch/`. That directory contains only disposable check output.
