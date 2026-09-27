# Frontend validation

Worker report, 2026-09-27. These checks are local evidence, not independent
certification or the later publication gate.

## Scope and consequential decisions

Implemented the one-page RCPT / SwapReceiptHook frontend against source commit
`51df4c55089f07ec549f8388c1f3d7a9aab5040e`, with Vite/React/TypeScript source under
`web/`, the complete export under `dist/`, and documentation/evidence under `docs/`.
Solidity, dependencies under `lib/`, Foundry configuration, root configuration and
deployment artifacts were preserved. Both supplied protected test definitions were
read as contract context; Foundry suites were not rerun for this frontend-only change.

Two conflicting requirements were resolved within the overriding task scope:

1. The root `DESIGN.md` request conflicts with the explicit allowed paths. The full
   design record is delivered as `docs/DESIGN.md`; no root file was created.
2. The specific workflow requires PoolSwapTest, but the generic network table lists
   Universal Router and Permit2 and does not contain PoolSwapTest. The exact network
   object is preserved unchanged. The explicitly supplied PoolSwapTest address lives
   in the manifest's `execution` extension. Quoter/StateView/PoolManager come from the
   network object. Approval targets the actual PoolSwapTest spender. The unrelated
   Universal Router/Permit2 recipe is not used. Price-limit/partial-fill limitations
   are shown beside the form and explained in `web/README.md`.

The only allocated ignore-file path is `web/.gitignore` (recursive dependency/cache
and archive exclusions). No other ignore file was created or changed. No backend,
publication, contract redeployment or real transaction broadcast is part of delivery.

## Commands and results

Commands run from `web/` unless specified otherwise:

| Check | Result |
| --- | --- |
| `npm install --cache /tmp/receipt-npm-cache --no-audit --no-fund` | Installed dependencies and created the frontend-only lockfile |
| `npm run typecheck` | PASS after the final application changes |
| `npm run build` | PASS; pinned ABI checks, Vite export, then deployment manifest emission |
| `npm run check:export` | PASS; nine assets; 553,890 bytes including manifest |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers npx playwright install chromium` | Installed temporary browser outside submission paths |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers npm test` | PASS; 27 production-export interaction/reflow checks |
| `npm run check:chain` | PASS; live Sepolia chain ID, bytecode, manager bindings and views |
| `node scripts/check-simulation.mjs` | PASS; live quoter and price-limited buy simulation via read-only `eth_call` |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/receipt-browsers node scripts/browser-live.mjs` | PASS; real browser/public RPC reads, no wallet and no mocks |
| `git diff --check` (root) | PASS |

The supplied MCP browser failed before navigation because its managed Chrome binary
was absent. The fallback used installed Playwright Chromium 141.0.7390.37 with an
HTTP server owned and closed by each foreground test process. Both interaction and
live-browser checks served the final export under `/preview/`, exercising gateway
subpath loading. No test harness is included in the production export.

## Deployment and chain evidence

`docs/evidence/live-chain.json` records RPC chain 11155111 and nonempty runtime code:
RCPT 2,456 bytes; SwapReceiptHook 13,311; PoolSwapTest 6,950; PoolManager 24,009;
StateView 3,531; Quoter 5,820. Both manager getters match the network PoolManager.

`docs/evidence/live-simulation.json` records a quote and simulated buy of
0.001 ETH returning `49627085152468411915572` RCPT base units through the specified
router. The RPC temporarily overrides the test account's balance for this `eth_call`;
no account was actually funded and no receipt was persisted. This checks real deployed
router encoding and settlement in simulation, not wallet signing or mined execution.

The live browser observed 50,000,000 RCPT per ETH and zero hook receipts at block
11,791,771. The pool price is read from StateView, not inferred from the handoff's
initial-price field. These are point-in-time observations, not fixed UI defaults.

The build and export checker verify raw implementation ABI bytes from the pinned
Git source and canonical Keccak hashes:

- RCPT: `f36d2fe28b62f817a4fba0b78bb501b41895eada3982280273c063ad8183f577`
- SwapReceiptHook: `83ae4889f064d952a051e414d1d6d13052e3234a5b4ced8c2eb0e73879d2e728`

The runtime configuration is `dist/imd-deployment.json`. Its exact contract set,
identifiers, unchanged network/wallet parameters, relative ABI paths, and complete
lowercase SHA-256 inventory pass the export checker. The manifest is generated after
the last Vite export and excludes itself. Individual assets are below 8 MiB and the
export has substantial room below both the Git submission and HTTP response budgets.

## Interaction coverage

Machine-readable outcomes: `docs/evidence/interactions.json`. All wallet requests
and transactions in this suite are mocked. Assertions cover:

- Missing wallet and rejected connection; wrong chain disables trading; error 4902
  produces exact add-chain parameters and another switch; public RPC fallback.
- Manifest-bound StateView/pool ID; latest 12 based on views and Receipt logs;
  filtering of other tokens and other pools; owner pagination and tokenURI images;
  pasted-address validation and focus recovery.
- Invalid/zero amounts and invalid tolerance; sub-micro-unit display; buy quote and
  negative exact-input router encoding; correct native value, test settings, price
  bound and 32-byte wallet hookData; quotes never request signing.
- Wallet rejection, simulation revert, partial fills and below-threshold warnings;
  exact-amount sell approval to the correct spender; no Permit2 approval; repeated
  simulation before confirmation; success receipts, explorer links and refreshed state.
- Expired and changed-account reviews; missing deployed code; tampered ABI rejection;
  Enter/Space keyboard operation; local resource and JavaScript error monitoring.

## Better Interface consolidated review

Read the pinned workflow and core principles for all six domains, relevant keyboard,
form, motion, typography and token guidance, and the documentation method. Applied
the guidance throughout implementation; this is a self-review, not an independent audit.

| Domain | Coverage and evidence | Limitations |
| --- | --- | --- |
| Accessibility | Checked native controls/labels, landmarks, alt text, error/status semantics, skip link, visible keyboard focus, Enter/Space flow, axe WCAG A/AA scan. Zero automated violations. | No real screen reader or physical touch device. Axe marks decorative symbols/pseudo-element contrast for manual inspection; this is recorded rather than discarded. |
| Layout | Checked source grids and shared edges; screenshots and overflow assertions at 1440, 768, 390 and 320px; 200% root text enlargement at 768px. | Text enlargement is not browser-native zoom. No translated/RTL version. |
| Writing | Checked primary actions, network/rejection/revert recovery, testnet labeling, transaction steps, empty states, partial fills and unauthenticated hookData explanation. | English only. |
| Typography | Checked heading hierarchy, labels, numeric alignment, input sizes, address wrapping and rendered desktop/mobile copy. Tiny output amounts retain significant digits. | System font substitutions vary by OS; decorative illustration lettering is smaller than functional UI text. |
| Colors | Checked semantic token roles and rendered colors. Measured body/page 13.77:1, muted/page 5.30:1, helper/card 5.84:1, primary/lime 12.39:1, sample label/paper 5.84:1. | No dark theme. Not every NFT image or status combination was independently contrast-measured. |
| UI details | Checked pressed/selected/disabled/loading/empty/error/success states, restrained 120ms transitions, reduced-motion configuration, card radii, image boundaries, usable touch control sizes. | Forced-colors styles reviewed in source, not a full Windows high-contrast session; no 10%-speed animation-panel session. No modal/autoplay checks apply. |

### Findings fixed and rechecked

| Severity | Source | Finding, fix, evidence |
| --- | --- | --- |
| High | `web/src/main.tsx:189` | Account/network/input changes must invalidate in-flight reviews. Added epoch and fingerprint checks plus fresh wallet verification; changed-account and expiry tests pass. |
| Medium | `web/src/main.tsx:190` | Refreshing live verification cleared confirmation text. Separated status clearing from readiness invalidation; confirmation and subsequent approval/review flows pass. |
| Medium | `web/src/styles.css:46` | Rotated decorative orbit extended the 768px document to 779px. Clipped decoration within its own scene. Final reflow assertions pass at all four widths. |
| Medium | `web/src/styles.css:168` | An off-screen fixed skip link appeared in full-page screenshots. Used clipped visually hidden positioning until focused; final focus screenshot and keyboard checks pass. |
| Medium | `web/src/main.tsx:133` | Generic div labels were flagged for manual ARIA review. Added appropriate image/group semantics for illustration and statistics; the ARIA finding is absent from the final scan. |
| Medium | `web/src/chain.ts:5` | Six-decimal display rounded tiny positive output to zero. Switched small nonzero values to significant digits; a one-wei input test passes. |
| Low | `web/src/styles.css:190` | Mobile illustration caption overlapped a secondary decorative sentence. Removed that sentence and increased scene space; final live-mobile screenshot rechecked. |

### Rendered evidence

- `docs/evidence/live-desktop.jpg`, `live-mobile.jpg`, `live-full-page.jpg`: actual
  public-RPC state, disconnected wallet, no mocks. Desktop and mobile images were inspected.
- `docs/evidence/desktop-review.jpg`: mocked populated gallery and simulated buy review.
- `docs/evidence/mobile-390.jpg`, `mobile-320.jpg`: mocked populated responsive states.
- `docs/evidence/keyboard-focus.jpg`: focused native navigation control.
- `docs/evidence/accessibility.json`: full automated violations, incomplete targets,
  and passed rules. `browser-live.json` records measured rendered color pairs and
  zero page errors/failed requests in the live session.

Mock screenshots demonstrate layout and interactions; they are not claims of live
NFT holdings, live mint transactions or published site state. The actual live hook
had no receipts at inspection time. The contract's SVG layout is represented by
test metadata; the production application exclusively loads real tokenURI values.

## Remaining limitations and completion

No live wallet extension was connected and no real approval, sell, buy or mint was
broadcast. Those interactions are validated with mocks; a real buy was additionally
checked by ephemeral RPC simulation. Sell settlement with an actual funded holder,
wallet-specific prompts, replacement/cancellation UX, receipt reorgs, external RPC
availability, Safari/Firefox and physical devices were not end-to-end verified.
RPC code-presence checks do not establish runtime bytecode identity or constitute
a contract security audit. Receipt crediting remains intentionally unauthenticated.

PoolSwapTest's lack of minimum-output/deadline parameters is an explicit router
limitation. UI expiry cannot cancel an already signed transaction; price bounds remain
its on-chain protection. No claim is made that publication checks execute browser code.

Complete for the authorized frontend implementation, static export and worker
validation scope, with the root design-file substitution described above. The
workspace Git metadata is mounted read-only: `git add web dist docs` failed creating
`.git/index.lock`. To preserve the requested committed delivery, an isolated repository
under disposable `test/scratch/` contains the delivery commit, exported as
`docs/receipts-frontend.bundle`. The bundle is not included in its own commit. See
`docs/DELIVERY.md` for import and size details. The workspace itself remains uncommitted
because of that filesystem restriction. Publishing, IPFS naming and subsequent
control-plane checks remain the publisher's work.
