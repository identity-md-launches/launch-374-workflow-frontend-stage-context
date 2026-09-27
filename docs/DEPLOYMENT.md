# Deployment: parameters, assumptions, responsibilities

This document is what the manifest author, the reviewer and the operator need from the source
side. On-chain values come from the factory and `launch.json`; everything below is what the source
fixes and what the Foundry rehearsal mirrors.

## Deployment parameters

| Parameter | Value | Where fixed |
| --- | --- | --- |
| Chain | Sepolia, chain id 11155111 | `LaunchConfig.CHAIN_ID` |
| Token | `RCPT`, no constructor arguments, 1,000,000,000 × 10^18 minted to the deployer | `src/RCPT.sol` |
| Hook | `SwapReceiptHook`, constructor `(IPoolManager)` | `src/SwapReceiptHook.sol` |
| Hook constructor argument | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (Sepolia PoolManager) | `LaunchConfig.SEPOLIA_POOL_MANAGER` |
| Hook address bits | exactly `0x0040` (`afterSwap`); CREATE2 salt mined for them | `LaunchConfig.HOOK_FLAGS`, `HookMiner` |
| Pool key | `currency0` = native ETH (address 0), `currency1` = RCPT, fee 3000, tickSpacing 60 | `LaunchConfig` |
| Receipt threshold | 0.001 ETH settled per buy | `SwapReceiptHook.MIN_ETH_PAID` |
| ERC-721 name / symbol | "Swap Receipts" / "SWAPRCPT" | string literals in source |
| Rehearsal opening tick | 138180 (≈ 1,001,800 RCPT per ETH; 0.001 ETH ≈ 1,000 RCPT) | `LaunchConfig.INITIAL_TICK` |
| Rehearsal opening sqrtPriceX96 | 79299443975792720780679863727831 (= `TickMath.getSqrtPriceAtTick(138180)`) | `LaunchConfig.INITIAL_SQRT_PRICE_X96` |
| Rehearsal seed | whole supply as one-sided RCPT liquidity in ticks [-887220, 138180] | `LaunchConfig.SEED_*` |
| Site reads | StateView `0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C` | `LaunchConfig.SEPOLIA_STATE_VIEW` |
| Site swaps through | PoolSwapTest `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe` | `LaunchConfig.SEPOLIA_POOL_SWAP_TEST` |
| Compiler | solc 0.8.26, via_ir, cancun, `bytecode_hash = "none"`, `cbor_metadata = false` | `foundry.toml` |

The hook depends on none of the pool price or seed parameters. They are recorded so the manifest,
the rehearsal and the factory can be checked against each other.

## Assumptions

1. **The factory deploys.** No script in this repository is meant to broadcast on Sepolia.
   `script/Deploy.s.sol` shows the same shape for a fork or a local chain and is what the tests
   exercise. The factory is expected to: deploy `RCPT` (receiving the supply), mine a CREATE2 salt
   for bit `0x0040`, deploy the hook with the PoolManager as the only argument, `initialize` the
   pool at the manifest price, and add one-sided RCPT liquidity. The hook cannot revert any of
   those steps because it enables no callback other than `afterSwap`.
2. **Opening price and seed.** The rehearsal opens at tick 138180 and seeds the whole supply in a
   position ending at that tick, so the position holds only RCPT and every buy walks the price down
   into it. If the manifest chooses another price or share, the rehearsal constants in
   `script/LaunchConfig.sol` should be updated to match; the hook's behaviour does not change.
3. **The first buy lands in a pool with no ETH.** Rehearsed: a 0.001 ETH exact-in buy against the
   one-sided seed mints receipt #1 and leaves the manager holding exactly 0.001 ETH.
4. **Sepolia contracts are as published.** The PoolManager, PoolSwapTest router and StateView
   addresses above are Uniswap's published Sepolia deployments and are used by the site, not by the
   contracts. The hook only needs the PoolManager address to be correct at construction.
5. **PoolSwapTest passes `hookData` through unchanged.** The site puts the connected wallet in
   `hookData`; any router that forwards it works the same way.
6. **v4-core is vendored at commit** `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (2026-04-02),
   OpenZeppelin Contracts at v5.4.0, forge-std at v1.11.0. The hook's on-chain behaviour depends
   only on the `IHooks` calling convention, which is stable across v4-core releases.

## Operational responsibilities

- **Before deployment.** The mined salt must produce an address whose low 14 bits are exactly
  `0x0040` for the factory's own CREATE2 deployer address and the exact creation code (runtime
  bytecode plus the ABI-encoded PoolManager argument). A wrong deployer, argument or compiler
  setting changes the address and the constructor will revert with `HookAddressNotValid`. The
  attested creation code should be built with the pinned `foundry.toml` so the verifier's floor
  suite judges the same bytes.
- **Manifest linkage.** `launch.json` must state the pool key above, the hook flags `0x0040`, the
  token's 18 decimals and the PoolManager address. Any disagreement with this document is a review
  finding, not something to reconcile in source silently.
- **After deployment.** There is nothing to administer. The hook has no owner, no setter and holds
  no funds. Operators should monitor `Receipt` events and, if an anomaly is found, the only
  remedies are off-chain (the site can stop showing the pool); the contracts cannot be paused or
  changed.
- **hookData spam.** Anyone can mint receipts to any address for 0.001 ETH plus fees each. This is
  inherent and documented in the README and NatSpec; the site and any downstream consumer must not
  treat a receipt as proof that its owner made the buy. If the site filters receipts, it should
  filter on the launch pool's `poolId` (from the `Receipt` event) and token address, not on owner.
- **Gas.** The minting callback costs about 143,000 gas on the first mint ever, about 126,000 for a
  later first mint to a new owner and about 109,000 for a repeat, measured from a contract in the
  pool manager's position. A buyer's total swap cost through PoolSwapTest with a mint is about
  360,000 gas in the rehearsal.
- **Other pools.** Any native-ETH pool that names this hook mints receipts recording its own
  `currency1`. Any non-ETH pool gets zero deltas and nothing else. Neither can affect the launch
  pool's accounting.

## What the adversarial review should attack

Handed over as a checklist so the reviewer can start from the call sequences the tests already
cover (`test/SwapReceiptHook.t.sol`):

1. Any input that makes `afterSwap` revert and so blocks a buy: extreme deltas
   (`type(int128).min`), malformed `hookData` (wrong length, dirty upper bytes, zero), contract
   recipients without `onERC721Received`, id growth, `tokenURI` for large values.
2. Any transfer or operator path that survives the soulbound override: `transferFrom`, both
   `safeTransferFrom`, `approve`, `setApprovalForAll`, and anything reaching `_update` or
   `_approve` by another route.
3. Under- or over-counting of `ethPaid` on exact-out buys and partial fills against the router's
   refund.
4. The unauthenticated `hookData` spam: anyone minting receipts to anyone for 0.001 ETH plus fees.
   Documented above; the review confirms it is documented rather than silently accepted.
