# Receipts (RCPT) and SwapReceiptHook

A Uniswap v4 launch on Sepolia. `RCPT` is a fixed-supply ERC-20. `SwapReceiptHook` is an
`afterSwap`-only hook on the token's native-ETH pool that is also a soulbound ERC-721: every buy of
at least 0.001 ETH mints one on-chain receipt to the address the swapper names in `hookData`.

Site label: `lab-receipt-nft-hook`.

## Contracts

| Contract | File | Constructor | Role |
| --- | --- | --- | --- |
| `RCPT` | `src/RCPT.sol` | none | "Receipts" / "RCPT", 18 decimals, 1,000,000,000 RCPT minted once to `msg.sender`. No mint, burn, owner or admin. |
| `SwapReceiptHook` | `src/SwapReceiptHook.sol` | `(IPoolManager)` | `afterSwap` hook and ERC-721 "Swap Receipts" / "SWAPRCPT". No owner, admin, setter, pause, upgrade or sweep. |
| `HookFlags` | `src/HookFlags.sol` | library | The fourteen permission bits and the address checks the deployer and the tests share. |

ABI exports: `docs/abi/RCPT.json`, `docs/abi/SwapReceiptHook.json`.

## What the hook does

- **Permissions.** Exactly `afterSwap`. The deployed address must carry bit `0x0040` and no other
  permission bit; the constructor calls `Hooks.validateHookPermissions` and refuses any other
  address. Initialisation, liquidity changes and donations never reach the hook, so nothing in it
  can revert the factory's pool initialisation or one-sided seed.
- **Deltas and funds.** `afterSwap` returns a zero delta on every path. The hook never takes,
  settles or holds funds and charges no fee.
- **Which swaps mint.** A buy (`zeroForOne`, ETH in) on a pool whose `currency0` is native ETH,
  where the ETH the pool actually settled, `|delta.amount0()|`, is at least `MIN_ETH_PAID`
  (0.001 ETH). Exact-in and exact-out buys, and partial fills, are all judged by the settled amount.
  Sells, dust buys, buys with no valid `hookData` address, and any swap on a pool whose `currency0`
  is not native ETH mint nothing; the hook has no other effect on such pools.
- **Identity.** The credited address is the 32-byte `hookData` word read as an address, exactly
  when `hookData` is 32 bytes long, non-zero and fits in 160 bits (what
  `abi.decode(hookData, (address))` would return). Anything else, including a word with dirty upper
  bytes, credits nobody without reverting. There is no fallback to the swap's `sender`: that is a
  router, which could never claim.
- **Receipts.** Ids start at 1 and rise by one. Each stores `ethPaid` (uint128 wei),
  `tokensReceived` (uint128, `|delta.amount1()|`), the pool's `currency1`, `blockNumber` and
  `timestamp`, and emits `Receipt(id, owner, poolId, ethPaid, tokensReceived, blockNumber)`.
  Receipts from other native-ETH pools on the same hook record their own token; the site shows only
  the launch token's.
- **Soulbound.** `_update` admits only mints, so `transferFrom` and both `safeTransferFrom`
  variants revert with `Soulbound()`. `_approve` and `_setApprovalForAll` revert, so `approve` and
  `setApprovalForAll` revert. There is no burn.
- **Minting never reverts a buy.** `_mint` is used, never `_safeMint`, so a contract recipient
  without `onERC721Received` still gets its receipt and cannot block the swap. The callback makes no
  external call. Measured from a contract in the pool manager's position, the first mint ever costs
  about 143,000 gas, a later mint to a new owner about 126,000 and a repeat mint to the same owner
  about 109,000, all under the 200,000 budget.
- **Views.** `totalMinted()`, `receiptOf(id)` (reverts for unknown ids), `receiptsOf(owner, offset,
  limit)` (a page of the owner's ids, oldest first, backed by a per-owner list), and `tokenURI(id)`:
  a base64 data URI of JSON with an SVG showing the id, ETH paid to six decimals, whole tokens
  received, the token address and the block; attributes carry the raw stored numbers. Reverts for
  ids that do not exist.
- **Caller checks.** Every callback requires `msg.sender == poolManager`. Callbacks the hook does
  not enable revert with `HookNotImplemented()` for everyone.

## hookData is not authenticated

The pool manager forwards `hookData` from whoever called `swap`. **Anyone can mint a receipt to any
address by paying for a qualifying buy** (0.001 ETH plus fees per receipt). A receipt therefore
proves that a buy of the recorded size happened on the pool and named that address. It does not
prove that the address made the buy, and it can be produced against an address's will. Anything
that consumes receipts, including the site's gallery, must treat them that way. The hook makes no
attempt to prevent this because there is no on-chain way to do so without a trusted router, which
the launch does not have.

## Deployment shape

The launch factory deploys both contracts on Sepolia and opens the pool; see
`docs/DEPLOYMENT.md` for parameters, assumptions and responsibilities.

- `RCPT` is deployed with no arguments; the factory, as `msg.sender`, receives the whole supply.
- `SwapReceiptHook` is deployed by CREATE2 with a salt mined so the address carries exactly the
  `afterSwap` bit, and with the Sepolia PoolManager
  `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` as its only constructor argument.
- The pool key is `currency0` native ETH, `currency1` RCPT, fee 3000, tick spacing 60, hooks = the
  hook. The factory initialises it and seeds one-sided RCPT liquidity; the first buy lands in a pool
  that holds no ETH.

`script/Deploy.s.sol` is a reviewable reference for the same shape (constants in
`script/LaunchConfig.sol`, salt mining in `script/HookMiner.sol`); its `deployHook` function is
what the tests call. Nothing in this repository authorises a transaction or controls a wallet.

## Build and test

```
forge build
forge test
forge fmt --check
```

The compiler is pinned to 0.8.26 in `foundry.toml` (`via_ir`, `evm_version = "cancun"`,
`bytecode_hash = "none"`). Dependencies are vendored as ordinary files under `lib/` with no
submodules; see each `lib/*/VENDORED.txt` for the upstream version.

Tests (`test/`) run against a real v4-core `PoolManager` deployed in the test, with the hook at a
mined address:

- `LaunchRehearsal.t.sol`: opens the pool exactly as the factory does (configured price, one-sided
  RCPT seed, no ETH), then the first buy of 0.001 ETH mints receipt #1.
- `SwapReceiptHook.t.sol`: permissions and address validation; caller checks; the 0.001 ETH
  threshold to the wei, exact-in and exact-out, partial fills, dust and fuzzed sizes; sells,
  missing, malformed and dirty `hookData`; contract recipients; a non-ETH pool; a second ETH pool;
  ids and events; views and pagination; `tokenURI` decoded and parsed; every transfer, approval and
  burn path; gas.
- `RCPT.t.sol`: supply, deployer, transfers, absence of admin entry points.

Tests read no environment variables and do not depend on the caller of any script. Passing tests
are not a security audit: the adversarial review in the workflow is a separate step.

## Layout

```
src/                 RCPT.sol, SwapReceiptHook.sol, HookFlags.sol
script/              Deploy.s.sol, LaunchConfig.sol, HookMiner.sol
test/                suites, test/utils (fixture, base64 decoder), test/mocks
docs/                DEPLOYMENT.md, abi/
lib/                 vendored forge-std, v4-core, openzeppelin-contracts, solmate (Owned only)
```
