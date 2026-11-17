# MyCarBook Service

Vehicle history on LUKSO for owners and the whole automotive chain: a free personal logbook, plus
attested service records from workshops, body shops, dealers and manufacturers, each working in its
own register. Access through the ChainIntegrate Account; personal data encrypted on ChainIntegrate's
IPFS node and shared only with the owner's consent.

> **Status.** This repository starts as a copy of [MyCarBook](https://github.com/ChainIntegrate/MyCarBook)
> (full history up to November 2026), the personal logbook live on LUKSO mainnet. Everything below
> describes that starting point, **MyCarBook V2**, as it runs today. The design of the new version
> is being written in `docs/DESIGN.md`.

**Live (V2)**: https://mycarbook.chainintegrate.it

## Layout

```
├── contracts/
│   ├── MyCarBook.sol         — v1, historical, no longer used by the frontend
│   └── MyCarBookV2.sol       — v2, DEPLOYED and IN USE on testnet and mainnet
├── scripts/
│   ├── deploy.js             — v1 deployment
│   └── deploy-v2.js          — v2 deployment
├── backend/
│   ├── server.js             — start-up; logic in lib/ (app, auth, files, schema)
│   ├── lib/                  — pinning to ChainIntegrate's IPFS node, with an ERC-1271
│   │                           signature bound to the content; CID collection and pin operations
│   ├── scripts/              — check-pins (check / re-pin / orphans), CAR backup
│   ├── test/                 — backend negative tests (node --test)
│   ├── allowed-addresses.json — manual list of addresses allowed to add a vehicle photo
│   │                           (NOT committed, lives only on the server — see .gitignore)
│   └── allowed-addresses.example.json
├── deploy/                   — Nginx vhost and security headers (CSP), systemd units
├── docs/                     — AUDIT.md (status of each finding), OPERATIONS.md, PRIVACY.md
├── tests/                    — frontend (jsdom) and end-to-end tests (Chromium + Nginx)
└── frontend/
    ├── index.html            — public UI, vanilla JS (js/app.js), mobile-first, EN/IT
    ├── privacy.html          — privacy policy (IT/EN)
    ├── js/, css/             — code and styles (no inline script or style: CSP)
    ├── vendor/, fonts/       — ethers, erc725.js and fonts served locally (SHA256SUMS)
    ├── admin-collection.html — admin page (contract owner): collection metadata and the
    │                           image of a single tokenId
    └── config.js             — contract addresses per network, ABI
```

## Current state (V2)

**MyCarBookV2 is the contract in use, deployed and verified on both networks**:
- Testnet (4201): `0xcf1e38bB8aB96B5b0100Af55dC7E7eF9D2e2DE60`
- Mainnet (42): `0x24e9cd569AC99B6DF47CA767508cF63105318195`

`MyCarBook.sol` (v1) stays in the repository for reference only; the frontend no longer uses it.

### What V2 adds to v1

- **Mileage fix**: `logIntervention` updates `vehicleInfo.km` only when the new value is higher than
  the highest recorded, so a backdated entry with a lower mileage never moves the odometer back.
- **`categoryFlags`** (a `uint8` bitmask) on every entry; categories can be combined:
  `CATEGORY_MECHANICAL=1`, `CATEGORY_BODYWORK=2`, `CATEGORY_TIRES=4`, `CATEGORY_ELECTRICAL=8`,
  `CATEGORY_CLEANING=16`, `CATEGORY_OTHER=32`.
- **Document attached to an entry**: an on-chain hash was considered and **dropped** (too "certified"
  for the project's purpose). Adopted instead, as a convenience with no hash: the IPFS link is appended
  to the `description` with a `[doc:ipfs://...]` marker, which the UI recognises and shows as a link.
  No dedicated field in the contract.

### Gated uploads and storage

> Updated after the audit of 4 November 2026: see [docs/AUDIT.md](docs/AUDIT.md).

Every call to `/api/pin-file` and `/api/pin-json` needs an **ERC-1271 signature**, checked by the
backend before it pins anything:

1. The frontend signs, with the connected Universal Profile, a message holding the domain, the
   `purpose`, the address, the network, the **SHA-256 fingerprint of the file or JSON**, a random
   nonce and the time: one more confirmation in the UP, besides the transaction.
2. The backend checks the signature with `isValidSignature` (ERC-1271) on the caller's UP: valid for
   5 minutes, **once**, for that content only, on mainnet only (chainId 42).
3. Only then it checks the permission for the `purpose`:
   - `metadata` (`/api/pin-json`, mint) → any UP, JSON with a strict schema
   - `photo` → the manual list **or** tier Bronze and above
   - `document` → tier Gold
   - `admin` → the owner UP (`ADMIN_UP_ADDRESS`); `ADMIN_SIGNER_ADDRESS=any` accepts any of its
     controllers with the SIGN permission, an address restricts it to one key (from `.env`)

The file type comes from its bytes (JPEG/PNG/WebP, PDF for documents only); photos must arrive without
EXIF (the app re-encodes them). Rate limit per real IP (`trust proxy` loopback behind Nginx).

**Storage**: moved from Pinata to [ChainIntegrate's IPFS node](https://ipfs.chainintegrate.it) (Kubo,
dedicated server, `Gateway.NoFetch=true`: it serves only content pinned by ChainIntegrate). The pinning
API (`:5001`) is reachable only from the production server's IP (network allow-list; `IPFS_API_AUTH` is
supported too). The files pinned earlier on Pinata were re-pinned on the node on 16 November 2026, and
a daily check re-pins anything missing (MCB-17); LUKSO's gateway stays as a fallback.

### Tier-based features, through ChainIntegrate Membership

Three UI features are unlocked by the tier held in
[ChainIntegrate Membership](https://github.com/ChainIntegrate/chainintegrate-membership) (read on-chain
with `tierOf(address)`, no manual sync). Each tier includes the ones below:

| Tier | Indicative price | Unlocks |
|---|---|---|
| Bronze | ~50 LYX | Vehicle photo at mint |
| Silver | ~200 LYX | + Service categories (check boxes) |
| Gold | 500 LYX | + A document attached to an entry |

Prices are neither applied nor checked by the contract (the membership mint is `onlyOwner`, handled by
hand by ChainIntegrate after an off-chain payment): an operating convention, not written in the code.

The **vehicle photo** has a second way in, independent of the membership: being listed in
`backend/allowed-addresses.json` (manual list, historical, kept for compatibility).

The new version replaces the membership with the ChainIntegrate Account and a service authorization
(see `docs/DESIGN.md`).

### Self-service paid mint (considered, not implemented)

A fully self-service membership mint/upgrade (the user pays in LYX, the contract mints or upgrades by
itself) was considered. Not possible without a new deployment: mint and upgrade are `onlyOwner`, and
`Ownable` allows a single owner, so handing ownership to an operating key in the backend would have
taken the manual management away from ChainIntegrate's own UP. Decided **not** to proceed.

- **Image of a single tokenId after the mint**: handled by `admin-collection.html` (its own section);
  only the contract owner can do it (`setDataForTokenId` is `onlyOwner`). The page merges with the
  existing metadata, but the contract lets the owner replace the whole record of any vehicle, and the
  vehicle's owner cannot correct it alone (MCB-04: an accepted limit of V2).
- **Collection metadata** (icon, banner, description, shown on universaleverything.io at collection
  level): same page, separate section. Set on **both** networks.
- **Translations**: the UI's static texts and the labels of the on-chain `attributes` (Brand / Model /
  Trim / Plate / VIN, always stored in English) are translated on screen by the active language; the
  on-chain data stays unchanged.
- **Branding**: logo, favicon, banner, generated with an external AI tool.

## Design notes

- Fonts: Oswald (display, printed headings), Inter (body), JetBrains Mono (mileage, dates, amounts:
  odometer-like readability).
- Palette: petrol black with brass (`--brass`) as the only accent, engine green for positive states.
- Signature element: each entry is drawn as a logbook "stamp" (a dashed round badge with the date).
- `erc725.js` is an ESM bundle built locally (`frontend/vendor/`, `cd tests && npm run vendor`), no
  longer from esm.sh: the CSP allows only code served by the site.
- The contract owner (branding, metadata) and the deployer (who pays the gas) are always separate
  addresses, on both networks.

## Not implemented in V2 (deliberately)

- Self-service paid membership mint/upgrade (see above).
- No encryption of any data: an explicit V2 choice, consistent with resale use (a history a future
  buyer can check). The new version changes this: see `docs/DESIGN.md`.

## Tests

```
cd backend && npm ci && npm test      # backend: signature, schema, files, rate limit, IPFS pins
cd tests && npm ci && npm test        # frontend (jsdom) + end-to-end (Chromium, real Nginx)
```
