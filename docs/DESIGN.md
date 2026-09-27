# Receipts design

## Overview

A one-page Sepolia trading and receipt-browsing interface. Warm paper backgrounds,
dark ink, a lime primary action, and a tilted paper receipt establish the visual
character. The illustration is explicitly labeled; real NFTs render their own
contract-provided artwork. The hierarchy is introduction, live state, trading,
wallet collection, activity and deployment details.

This is the final implementation record for `web/src/main.tsx`, `styles.css` and
`tokens.css`. The requested root `DESIGN.md` is outside the explicit permitted paths;
this document is its scoped substitute.

## Colors

Canonical values are hex primitives in `web/src/tokens.css`; semantic variables
reference them and components consume the semantic variables.

| Token | Value | Role |
| --- | --- | --- |
| `--page` | `#f4f3ec` | Warm page background |
| `--surface` | `#fffefb` | Cards, inputs, paper illustration |
| `--inset` | `#eeeee7` | Amount panels, segments, empty state |
| `--hover` | `#e7e8df` | Neutral control hover |
| `--text` | `#232621` | Main text and ink |
| `--muted` | `#626659` | Supporting text and labels |
| `--border` | `#d7d9ce` | Grouping separators |
| `--control-border` | `#8c9083` | Input and button boundaries |
| `--accent` / `--accent-hover` | `#d7f45b` / `#c8e54b` | Primary action, receipt branding |
| `--focus` | `#205cbe` | 3px keyboard outline with 4px offset |
| `--danger` | `#a52e24` | Error text and invalid field border |
| `--warning` | `#805014` | Partial-fill and threshold notices |
| `--success` | `#427345` | Live-read status dot, accompanied by text |

Live-browser measured contrast: body text/page 13.77:1; muted introduction/page
5.30:1; helper text/card 5.84:1; primary text/lime 12.39:1. These are measured pairs,
not a claim that every pixel or NFT image was audited. The app deliberately has one
light theme; contract-supplied dark NFT artwork retains its original colors.

## Typography

System fonts avoid external requests and font payloads. `--sans` is Arial,
Helvetica Neue, sans-serif; `--serif` is Georgia, Times New Roman, serif;
`--mono` is Courier New, monospace. Platform fallback and synthesized intermediate
weights can differ; no custom font file is claimed to have loaded.

- Main heading: responsive 3.65–6.25rem, 1.04 line height, −0.075em tracking, weight
  500. At the tablet breakpoint it is 64px; mobile uses a 15vw clamp.
- Section headings: 2–3.1rem, 1.12 line height, −0.05em tracking, weight 500.
  The italic serif marks a short phrase while retaining the semantic heading.
- Body: 16px, line height 1.55; introduction 17px/1.7 (16px on mobile).
- Form labels and helper copy: 12–15px. Inputs are at least 16px on mobile; the
  amount input is 34px. Compact metadata uses 10–11px monospace. Tiny barcode and
  sample captions are decorative illustration content, not transaction instructions.
- Numeric state uses tabular figures. Headings balance wrapping; descriptions use
  pretty wrapping. Addresses wrap anywhere and remain selectable. Story paragraphs
  are capped at 38 characters on desktop and 55 on mobile.

## Layout

`.shell` caps the overall width at 1296px with 48px inline padding, then 32/24/20/16px
at successive widths. Shared edges align the header, hero, statistics, sections and
footer. Related elements use 8–16px gaps; groups use 24–32px; major sections use
36–76px vertical padding. The desktop hero and trading section each use two columns.

Breakpoints are `68rem`, `50rem`, `42rem`, and `23rem` in `styles.css`. The network
badge gives way at 68rem and navigation links at 50rem; all sections remain in normal
page flow and accessible by scrolling. At 42rem the hero and trading section stack,
address input and button wrap, and activity rows become two-column records with
inline labels. Receipt cards move from four to three to two columns, then one below
23rem. Deployment details become one column. Decorative orbits are clipped within
the illustration so they cannot create page overflow; interactive content is not clipped.

Rendered checks cover 1440, 768, 390 and 320 CSS pixels. Root text enlargement to
200% was checked at 768px; browser-native zoom was not. The site is English-only;
full RTL/localization behavior is not verified.

## Elevation & Depth

The trade card uses `--shadow`: `0 3px 6px #23262103, 0 12px 32px #23262106`.
The illustration uses `--paper-shadow`: `0 3px 8px #23262108, 10px 20px 40px #23262112`.
Thin separators establish section structure. The wallet disclosure is the sole
small overlay; it stays within the viewport. There are no modal dialogs or sticky
transaction actions. NFT images use a 1px black outline at 10% opacity.

## Shapes

Controls have 8px radii, amount panels 12px, receipt cards 14px and the trade card
20px. Native buttons are at least 44px high; the filled primary action is 50px.
The selected trade segment is 40px high with a neutral raised surface. Coin and
step markers are circular. The illustrative receipt has square paper edges, a
CSS perforation pattern and an 8-degree tilt; it never animates.

## Components

All component implementations are in `web/src/main.tsx`, styled in `styles.css`:

| Component / pattern | Intended use and states |
| --- | --- |
| `Mark` | One inline SVG receipt mark; `small` variant; decorative to assistive technology |
| `OutLink` | External explorer link with visual arrow and safe new-tab attributes |
| `Trade` | Buy/sell segments, labeled amount/tolerance, quote and simulation, approval, confirmation, pending hash, success/rejection/revert, expiry |
| `ReceiptCard` | Raw tokenURI image with meaningful alt text, receipt number, ETH/RCPT amounts, explorer link |
| `.primary` | Exactly one emphasized next transaction step; unavailable prerequisites use native disabled state and explanatory text |
| `.empty-state` | Explains the collection and how to populate it; distinct loading and no-results text |
| `.activity-row` | Newest-first receipt event record; mobile labels preserve meaning when the column header is hidden |
| `.deployment-details` | Native disclosure containing full addresses, ABI links, pool and source data |

Controls have native keyboard semantics. Labels are bound to inputs, invalid input
focuses its field, transaction progress uses a persistent polite live region, and
errors use alert regions. Keyboard focus is visible; forced-colors uses system
Highlight. Buttons transition only background and transform for 120ms, with a 0.96
press scale, solely under `prefers-reduced-motion: no-preference`. There is no entrance
animation, autoplay or essential information conveyed only through motion.

## Do's and Don'ts

- Reuse semantic tokens, `.shell`, section headings, field patterns and native controls.
- Keep the next transaction action clear; simulate and verify prerequisites before signing.
- Label fixture/illustrative artwork. Real receipt data must come from the manifest-bound hook.
- Keep address and hash values accessible in full; do not abbreviate the only available copy.
- Keep clear explanations of price limits, partial fills, gas and unauthenticated crediting.
- Do not add another deployment map, a new token palette, remote fonts or hidden signing steps.

For another section on this page, reuse `.section-heading`, a content grid with
`minmax(0, 1fr)`, and existing controls. Recheck 320px reflow, keyboard access and
manifest asset inventory after changing the export.

Design guidance attribution: Jakub Krehel, Better Interface (MIT), pinned commit
`267330e1adfc66a718fb65fa6918c1f06d0a689e`. Documentation method: Paul Bakaus,
Impeccable (Apache-2.0), commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`,
<https://github.com/pbakaus/impeccable/blob/9d715cc4f5564a990ca8345abfdd5df6dc9b41c8/skill/reference/document.md>.
The pinned guides were read and applied; their source text is not redistributed here.
