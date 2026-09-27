# Receipts frontend

A single-page Vite / React / TypeScript interface for the deployed RCPT token and
SwapReceiptHook on Sepolia. The complete static site is in repository-root `dist/`.
No server, secrets, CDN assets, or WalletConnect project ID are required at runtime.

## Install, build, preview

Use Node 22.12+ (validated with Node 24.9.0 and npm 11.6.0):

```sh
cd web
npm ci
npm run typecheck
npm run build
npm run check:export
npm run preview
```

Open the URL printed by Vite. After editing source, run `npm run build` again and
reload the preview. `vite.config.ts` uses `base: './'` and writes to `../dist`.
All sections use hash anchors; hosting at a gateway subpath needs no route rewrites.
Serve files over HTTP(S), not `file://`, because the application fetches JSON.
The publisher can host the delivered export without installing dependencies or rebuilding.

## Deployment configuration and ABI provenance

Build inputs are grouped under `web/`:

- `deployment.json`: unchanged deployment handoff, including deployed source commit,
  attestation, complete contract set, addresses, ABI hashes and launch pool parameters.
- `network.json`: unchanged network handoff, including public RPCs, vetted Uniswap
  addresses and exact `wallet_addEthereumChain` parameters.
- `execution.json`: the assignment's explicit PoolSwapTest router and protocol ABI paths.
  This router is not present in the supplied network table; the table is preserved unchanged.
- `public/abi/`: implementation ABIs plus the minimal StateView, V4Quoter and PoolSwapTest
  interfaces. PoolSwapTest's ABI matches `lib/v4-core/src/test/PoolSwapTest.sol` at the pinned commit.

`scripts/prepare.mjs` reads `docs/abi/<Contract>.json` using `git show` at
`51df4c55089f07ec549f8388c1f3d7a9aab5040e`. It verifies canonical Keccak-256
(recursively sorted object keys, preserved array order, compact JSON UTF-8) against
each handoff `abiHash` before copying the original bytes. Rebuilding therefore
requires that source commit to be available in the Git object database. It does
not compile or change deployed Solidity.

After Vite finishes, `scripts/manifest.mjs` emits `dist/imd-deployment.json`, preserving
all required identity fields and contract bindings, the unchanged `network` object,
and the exact `walletAddChain`. Additional fields are `pool`, `deploymentBlock` and
`execution`. Its SHA-256 inventory includes every exported file except itself.
Never edit an export file after this step; rebuild to regenerate hashes.

The browser fetches **this same manifest** and its referenced ABI JSON. There is
no compiled-in deployment address, chain or public-RPC map. `src/config.ts` verifies
contract ABI hashes at runtime, derives the pool key/ID, and creates clients from
the manifest. `scripts/check-export.mjs` checks exact handoff/network equality,
pinned ABI bytes, complete asset inventory, relative URLs and export limits.

## Trading and receipt behavior

The wallet connector supports the injected EIP-1193 browser provider (`window.ethereum`),
including wallet in-app browsers. Without a provider the page remains readable and
offers a clear setup error. WalletConnect and multi-provider selection are not included.
Switching an unknown chain offers the handed-off add-chain request and retries switching.
Local disconnect clears this page's connection; it does not revoke wallet permissions.

Reads use the configured public RPCs in order, with the connected wallet RPC as a
fallback only on the configured chain. Before enabling trades, and again before
signing, the app checks RPC chain ID, nonempty code for both contracts and required
Uniswap contracts, and the hook/router PoolManager bindings. Live reads refresh every
30 seconds while visible. Failures disable trading and expose retry controls.

This assignment specifically requires **PoolSwapTest**, so it takes precedence over
the background Universal Router recipe and the generic network-address wording.
StateView and quotes use the network table's addresses. Swaps use only the explicit
PoolSwapTest address in the runtime manifest; sell approvals target that same router.
The unchanged table's Universal Router and Permit2 are intentionally unused.

The form supports exact-input buys and sells. Quotes use V4Quoter's
`quoteExactInputSingle` through `eth_call` (`simulateContract`). The connected account
is encoded as one 32-byte ABI address in both quote and swap hookData. Buys send the
entered ETH value with no approval. Sells require an explicit, separately simulated
exact-amount ERC-20 approval to PoolSwapTest, followed by a new swap review. Neither
NFT approvals nor Permit2 approvals are made.

PoolSwapTest has **no minimum-output or deadline parameter**. The form says this and
provides a 0.1–5% pool-price tolerance (default 0.5%) enforced by `sqrtPriceLimitX96`.
For a buy, its squared limit is the quoted squared price times `(1 − tolerance)`;
for a sell it is divided by `(1 − tolerance)`, bounding the reciprocal ETH/RCPT rate.
Integer square root avoids floating-point encoding. This is a terminal pool-price
bound, not a guaranteed minimum output. The quote is a reference; the actual router
simulation displays input consumed and output under the price bound. Partial fills
are allowed and unused input is refunded or unspent. Gas is additional. Pending
transactions can still execute later within that price bound; the 60-second UI review
expiry is not an on-chain deadline. A post-approval partial sell can leave allowance
for the unspent part of the explicitly approved amount.

The app simulates the router before displaying confirmation and again before asking
the wallet to sign. Changed amounts, account, network, verification state or expired
reviews invalidate confirmation. A changed simulation requires a new review. Transaction
hashes link to the explorer; receipt status is checked, including reverted transactions.

A settled native-ETH buy of at least 0.001 ETH mints one soulbound receipt. Dust buys
and sells mint none. The gallery pages `receiptsOf` and filters `receiptOf.token` to
the launch token, then displays the on-chain `tokenURI` SVG in an image element.
It never inserts SVG markup into the DOM. Latest activity scans newest IDs and queries
`Receipt` logs at their exact mint blocks, filtering both token and launch pool ID.
Scans are bounded to 120 IDs per request, with an explicit continuation if other pools
dominate; wallet pages inspect 12 IDs at a time.

**hookData is unauthenticated. Anyone can credit any address with a qualifying buy.**
A receipt proves a buy named an address, not that the credited address traded. The
page states this next to the gallery. The hook has no admin, mint, pause or upgrade
action for a visitor; receipt transfer, approval and burn operations are unavailable
by contract design. RCPT transfer/allowance semantics are used for swapping.

## Validation

```sh
cd web
npm run typecheck
npm run build
npm run check:export
PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers npx playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers npm test
npm run check:chain
node scripts/check-simulation.mjs
PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers node scripts/browser-live.mjs
```

The interaction test starts its own bounded foreground HTTP server, serves the real
export under `/preview/`, launches Chromium, mocks all wallet/RPC interactions, runs
axe, saves evidence under `docs/evidence`, and closes both browser and server. Test
wallets, tokenURI fixtures and transaction hashes are injected only by the test runner;
they are absent from the production bundle. The live browser check uses real public
RPC reads without a connected wallet. `check-simulation.mjs` additionally checks a
live quote and router `eth_call` with an ephemeral account balance override; this
requires Node 22.18+ for native TypeScript stripping. It creates no real funding,
swap or mint. No check broadcasts a real transaction.

See `../docs/VALIDATION.md` for results, remaining limitations, and the six-domain
Better Interface review. Design documentation is `../docs/DESIGN.md`; the root path
was excluded by the assignment's overriding write scope. Source, lockfile, manifest
and export are all deliverables. No IPFS pin, site naming, contract deployment or
publication is performed by this worker.

## Packaging

The only ignore-file budget is `web/.gitignore`. Recursive entries exclude dependency,
build-cache and test-report directories and package archives at every nesting level
under `web/`. Dependencies remain local and are not submitted; no registry mirror or
submodule is needed. Evidence screenshots are JPEGs, and the export is approximately
0.55 MB with nine inventoried assets. Bundle size is checked separately from asset limits.
