# Audit 2026-11 — MyCarBook (V2)

Review of the contract, backend, frontend and infrastructure of 4 November 2026 (reports
`04-mycarbook.md` and `audit-mycarbook.md`, revision `e38be66`). Each finding is tracked here with its
status. It concerns **MyCarBook V2** in the [MyCarBook](https://github.com/ChainIntegrate/MyCarBook)
repository, where the fixes were made: pull request numbers below are that repository's. The new
version designed in this repository starts from this state.

The repository is public: security findings still open are described in general terms until they are
fixed; the technical detail is added together with the fix.

Legend: ✅ fixed, with a negative test, in production · ⏳ open · 📌 accepted and documented limit: it
would need a new contract, not planned for V2 · ➖ finding not confirmed

Posture on 4 November: weak (1 High, 7 Medium, 7 Low, 2 Info). Fixes released to production on
16 November 2026 (MyCarBook PR #1 and following): see [Release](#release).

**Decision of 16 November 2026: no new contract for V2.** MyCarBook V2 stays a **self-declared**
logbook, not a certified history, with its limits written plainly in the app, in "How it works", in
the guide and in the [privacy policy](../frontend/privacy.html). The 📌 findings (MCB-04, MCB-08,
MCB-11, MCB-12) are accepted limits, like GasTrace's "Documented" / "Version 2" findings. Conditions:
- the contract's owner UP can replace the record of any vehicle: its controllers' permissions must be
  kept to a minimum (general report, GEN-01);
- owners' requests (correction, removal of plate/VIN, photo) are handled with the procedure in the
  privacy policy, section 7.
A new contract was to be reconsidered if MyCarBook were to be presented as a reliable history for
buying and selling (workshops, dealers), or if users grew enough to make manual corrections frequent:
that is the new version this repository is for.

## Method

- Before each fix, each finding was confirmed again in the code at `e38be66` (identical to `main` on
  4 November): files and lines are given below as **Present at e38be66**. The lines of `index.html`
  match the report except where noted.
- Each fix has a negative test that tries the bypass and checks it is refused; where useful also a
  counter-test that reproduces the problem with the previous version.
  - `backend/test/` (`cd backend && npm test`, 47 tests): the real backend (Express) with Universal
    Profiles simulated as in ERC-1271/LSP6 (ECDSA signature of a controller), Kubo node and RPC
    simulated over HTTP.
  - `tests/frontend/` (jsdom, 22 tests) and `tests/e2e/` (14 tests): Chromium with a fake UP extension
    and a simulated chain, pages served by **real Nginx with the vhost and headers of `deploy/nginx/`**
    (self-signed TLS), real backend behind Nginx.
- No contract deployment: no fix needed one (the parts that would are 📌). No key used.
- Not verifiable from the working session: the real chain and LUKSO gateway (network blocked), the
  server and the IPFS node. The procedures to run there are in [OPERATIONS.md](OPERATIONS.md).

## Security

- ✅ **MCB-01 — Stored XSS through vehicle metadata and the `[doc:]` marker** (High).
  Present at e38be66: `frontend/index.html:1057` (`<img src="${…}" onerror=…>` inside
  `card.innerHTML`, line 1059), `:1548-1551` (the marker's regex captures `"` and ends up in
  `<a href="${…}">`), `:1562` (`entry.innerHTML`); `escapeHtml` (`:1101`) did not encode quotes; no
  CSP (`:1-35`, and no header live).
  Fix:
  - all code moved from `index.html` to `frontend/js/` (and from `how-it-works.html` /
    `admin-collection.html`); styles in `frontend/css/`; no inline script, `on*` handler or `style`
    attribute;
  - chain/IPFS data is rendered only with `createElement` + `textContent`/properties
    (`js/lib/render.js`); `src`/`href` only from validated `ipfs://<CID>` links (`js/lib/ipfs.js`),
    otherwise no link or image; an invalid `[doc:]` marker stays text;
  - summaries use `html\`…\`` (`js/lib/html.js`): every value is encoded (quotes included) and
    `innerHTML` accepts only these fragments (static check in the tests);
  - strict CSP and headers in the vhost: `deploy/nginx/security-headers.conf` (`script-src 'self'`,
    `style-src 'self'`, `frame-ancestors 'none'`, `object-src 'none'`, `base-uri 'none'`,
    `form-action 'none'`), `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options`,
    `Permissions-Policy`, HSTS; included also in the `location` blocks with their own `add_header`.
  Tests: `tests/e2e/xss-csp.test.mjs` (poisoned vehicle pushed into the victim's UP, the report's
  payloads on icon, `[doc:]` and description: nothing runs, no `on*` attribute; CSP counter-test:
  injected `onerror`, `<script>` and `javascript:` are blocked; counter-test of the e38be66 template,
  which runs the payload), `tests/frontend/safe-render.test.mjs`,
  `tests/frontend/static-checks.test.mjs`, `tests/e2e/flows.test.mjs` (headers on the real vhost,
  pages without CSP violations).
- ✅ **MCB-03 — `/api/pin-json` unauthenticated** (Medium).
  Present at e38be66: `backend/server.js:174-201` (only the `LSP4Metadata` key checked, up to 1 MB,
  `:170`).
  Fix: ERC-1271 signature required here too, with the common format of MCB-09 (content, nonce,
  domain, network). Two purposes:
  - `metadata` (mint): any UP, but a **strict schema** (`backend/lib/metadata-schema.js`): only the
    fields the app writes, attributes Brand/Model/Trim/Plate/VIN, maximum lengths, images only
    `ipfs://<CID>`, no extra key, body at most 32 KB;
  - `admin` (admin page): only the configured admin UP (item 3).
  The rate limit stays (20 per 15 min, now per IP). Exactly the signed text is pinned, the same whose
  keccak256 the contract records.
  Note on the request for a "specific admin key": `/api/pin-json` also serves the mint, open to anyone
  by design. Reserving it to the admin key would have blocked users' mints; the admin key is required
  for the `admin` purpose, while a mint needs the signature of one's own UP plus the strict schema. An
  admin-only pin (mints handled by hand) is one line in `lib/app.js`.
  Pins of cancelled mints are handled by the orphan clean-up (MCB-17).
  Tests: `backend/test/pin-json.test.js` (no signature, controller of another UP, content changed after
  signing, replay, other domain, testnet, expired/future, extra keys, XSS payload in the icon,
  attribute not allowed, rate limit still active).
- ✅ **Item 3 — Admin uploads bound to the configured owner.**
  Present at e38be66: `backend/server.js:42-45` (owner hard-coded) and `:116-119` + `:97-106`: the
  signature of any controller of the owner UP with the SIGN permission was enough.
  Fix (`backend/lib/auth.js`): the admin UP is read from `.env` (`ADMIN_UP_ADDRESS`, to update when
  ownership moves); if missing, admin actions are disabled. `ADMIN_SIGNER_ADDRESS` chooses which of
  the UP's keys count:
  - `any` (**production choice since 16 November**): any controller of the owner UP with the SIGN
    permission, checked on-chain by `isValidSignature` through the KeyManager, so the signature works
    from every device;
  - an address: only that controller key (stricter, to update at every change of device);
  - empty: admin actions disabled (a configuration mistake does not open access).
  Why: binding to a single key protects only the admin uploads on ChainIntegrate's IPFS node, not the
  contract. A compromised controller of the owner UP with call permissions could still use
  `setData`/`setDataForTokenId` pointing to files hosted elsewhere: that risk is handled on the UP's
  controller permissions (general report, GEN-01), not in the backend. The signature bound to the
  content, single use, mainnet only, and the file checks stay in any case (MCB-09, MCB-10).
  Tests: `backend/test/admin.test.js` (`any` mode: another controller of the owner UP accepted;
  different UP → 403; key that is not a controller of the owner UP → 401; no `ADMIN_UP_ADDRESS` →
  403; invalid value → the server does not start. Address mode: another controller → 403, admin key
  for another UP → 403, key removed from the controllers → 401, empty variable → 403).
- ✅ **MCB-02 — One rate-limit bucket for everyone behind Nginx** (Medium).
  Present at e38be66: `backend/server.js:178-184`, `:214-220`, listening on 127.0.0.1 (`:254`), no
  `trust proxy`.
  Fix: `app.set("trust proxy", "loopback")` (configurable with `TRUST_PROXY`); the vhost sets
  `X-Forwarded-For $remote_addr`.
  Tests: `backend/test/rate-limit.test.js` (a client using up the limit does not block the others;
  counter-test with the previous configuration: global block).
- ✅ **MCB-09 — Loosely bound upload signature; list readable by anyone** (Low).
  Present at e38be66: `backend/server.js:62-64` (message without file, nonce, domain), `:92-95`
  (reusable for 5 minutes, clocks running ahead refused), `:32-35`/`:88` (testnet accepted),
  `:203-207` (public `GET /api/photo-access/:address`).
  Fix: the signed message holds domain, purpose, UP, network, SHA-256 of the content, a random nonce
  and the time; the server recomputes the fingerprint of the content received, consumes the nonce
  (single use), accepts only `ALLOWED_CHAIN_IDS` (default 42) and a clock up to 60 s ahead. The list
  check is a `POST /api/photo-access` signed by the UP itself ("Are you on the access list? Check"
  button). Same format in `backend/lib/auth.js` and `frontend/js/lib/auth-message.js` (dedicated test).
  Tests: `backend/test/pin-file.test.js`, `pin-json.test.js`, `photo-access.test.js`,
  `tests/frontend/logic.test.mjs`.
- ✅ **MCB-10 — File type decided by the client** (Low).
  Present at e38be66: `backend/server.js:226-229` (declared `mimetype`).
  Fix: type taken from the first bytes (`backend/lib/files.js`): photos only JPEG/PNG/WebP, documents
  also PDF; name and type of the pinned file decided by the server.
  Tests: SVG/HTML declared `image/png` refused, PDF not accepted as a photo, name `../../evil.html`
  replaced (`backend/test/pin-file.test.js`).
  Gateway part (16 November): checked live that `ipfs.chainintegrate.it` sent neither `nosniff` nor a
  CSP. Applied on the node's server the headers of `deploy/nginx/ipfs-gateway-headers.conf`:
  `nosniff`, `Referrer-Policy: no-referrer` and a CSP without scripts (`default-src 'none'`,
  `object-src 'self'` for plain PDFs), first in Report-Only. Checked: an image opened from the
  gateway, an encrypted attachment downloaded and opened by Traceability. To check again with the
  first plain PDF opened straight from the gateway (none on MyCarBook today).
- ✅ **MCB-07 — Vulnerable multer 1.x and body-parser** (Medium).
  Present at e38be66: `backend/package-lock.json` (multer `1.4.5-lts.2`, body-parser `1.20.6`, express
  `4.22.2`); multer ran before the signature check (`server.js:222`).
  Fix: multer 2.5.0, express 4.22.3, body-parser 1.20.9, qs 6.16.2, proxy-addr 2.0.8; `npm audit`: 0
  vulnerabilities. Signature and permissions are checked **before** reading the multipart; limits
  `files: 1, fields: 0, parts: 1`; every parser error becomes a 4xx.
  Tests: truncated multipart with and without signature → 4xx and the process alive, extra fields
  refused, file over 5 MB → 413 (`backend/test/pin-file.test.js`).
- ⏳ **MCB-13 — IPFS node API in clear, protected only by an IP filter** (Low).
  Present at e38be66: `backend/server.js:15-19`, `backend/.env.example:3`.
  Done: the address is no longer a default in the code (`IPFS_API_URL` required), support for
  `IPFS_API_AUTH` (Kubo `API.Authorizations`), test with a node requiring the header
  (`backend/test/pins.test.js`). Open, **accepted risk for now** (16 November): tunnel/TLS between
  server and node. Only files meant to be public travel on the link, the API port is not reachable
  from outside and the daily check reports missing files; to review if the node is to hold private
  data (procedure in OPERATIONS.md). The IP stays in the git history: the real protection is the
  node's firewall.
- 📌 **MCB-08 — Paid features not enforced by the contract** (Low).
  Present at e38be66: `contracts/MyCarBookV2.sol:131-158` and `:91-111`; `how-it-works.html:204/269`
  ("checked directly on-chain").
  Pinning on ChainIntegrate's node is already reserved to the right tiers (backend). The text now says
  the tier is read by the app and is a convenience of the app, not a rule of the contract. Limiting
  the category bits and checking the tier on-chain: for the next contract.
  Tests: `tests/frontend/static-checks.test.mjs` (sentence removed).

## Privacy

- ✅ **MCB-05 — "Visible only to you"; no notice on plate and VIN; no privacy policy** (Medium; High
  in the second report).
  Present at e38be66: `frontend/index.html:368`, `:547` (EN), `:655` (IT); plate/VIN fields
  `:403-409` without notice; no link to a privacy policy.
  Done:
  - text corrected in IT and EN ("…is public and permanent: anyone can read it, not only you");
    `og:description` no longer says "no backend";
  - next to plate and VIN: a notice that they are optional, public and permanent, linkable to the UP,
    with the advice to leave them empty; when either is filled, the acknowledgement box is required,
    otherwise the summary does not open;
  - under the entry's description: a notice that date, mileage, amount and description are public and
    permanent, and not to write personal data;
  - "How it works": the list of what is public, what can and cannot be deleted, contact; a "Data and
    privacy" link in the footer;
  - field inventory and reduction proposal: [PRIVACY.md](PRIVACY.md);
  - privacy policy in `frontend/privacy.html` (IT/EN, 16 November), with the same structure as the
    ChainIntegrate Account policy (up-onboarding): controller, what is public, what ChainIntegrate
    receives and keeps and for how long, third parties, corrections and deletion (what can and cannot
    be done), rights; linked from the app's footer and from "How it works".
  The guide on www.chainintegrate.it was corrected and published on 16 November.
  Tests: `tests/e2e/flows.test.mjs` (mint with a plate and no acknowledgement: no summary, no
  signature; text served), `static-checks`.
- ✅ **MCB-06 — Photos and documents pinned with EXIF/GPS** (Medium).
  Present at e38be66: `frontend/index.html:1255-1290` (original photo, `formData.append("image",
  file)` at `:1272`), `:1299-1325` (document); the backend forwarded the bytes unchanged
  (`server.js:243-244`).
  Fix: photos and image documents re-encoded in the browser with a `<canvas>` (`js/lib/image.js`: no
  EXIF, GPS, camera data); the backend **refuses** JPEG/PNG/WebP still holding EXIF/XMP/IPTC/text
  (also from the admin page, which now re-encodes). PDFs cannot be cleaned in the browser: the notice
  says so. Upload after the user's confirmation (already so); pins of cancelled mints/entries are
  removed by the orphan clean-up (MCB-17). Document upload error: it now stops the save with the right
  message (it used to say "photo").
  Tests: JPEG with EXIF GPS refused (`backend/test/pin-file.test.js`); in Chromium a photo with EXIF
  GPS is uploaded cleaned (`tests/e2e/flows.test.mjs`).
  ⏳ The node's `Reprovider.Strategy`: to evaluate on the node (OPERATIONS.md).
- ✅ **MCB-04 (texts) — "Nothing is ever deleted or overwritten"** (Medium).
  Present at e38be66: `how-it-works.html:194` (EN), `:259` (IT), `:216/:281`
  ("tamper-proof"/"non falsificabile"), `README.md:119-122`.
  Done: "How it works" has a "Who can change what" section: service entries changeable by no one;
  dates and starting mileage changeable by no one; vehicle data (name, brand, model, trim, plate, VIN,
  photo) not changeable by the owner, but replaceable by the ChainIntegrate account that manages the
  contract, for any vehicle. Same notice in the README and in the admin page.
  📌 The owner's power, and the owner of a vehicle being unable to correct their own data, stay
  (decision of 16 November). The same power is the procedure for owners' requests: a new record,
  corrected or without plate/VIN, and the old record removed from the node; the reference stays in the
  chain's history (privacy policy, section 7).
  Tests: `static-checks` (sentences removed).

## Functionality and reliability

- ✅ **MCB-17 — Vehicle data not on ChainIntegrate's own IPFS node** (Medium).
  Present at e38be66: `frontend/index.html:1028-1031` (own node, then LUKSO's gateway, silently);
  live check of 4 November: 3 metadata files and 2 photos only on LUKSO's gateway.
  Done:
  - `backend/scripts/check-pins.js`: collects from the chain every referenced CID (collection metadata
    and every vehicle's, replaced versions included, images cited, `[doc:]` documents), checks they
    are pinned on the node; `--repin` re-pins them from the IPFS network or, failing that, by
    importing a CAR from the fallback gateway (Kubo checks every block; a CAR with a different root is
    discarded); `--gc-orphans [--apply]` removes the pins uploaded by the backend and never used on the
    contract after 48 h, only when the CID list is complete;
  - `backend/scripts/backup-ipfs.sh`: exports the CARs of every CID with a SHA-256 manifest and copies
    them off the server (`BACKUP_REMOTE`, rclone or rsync); daily/weekly systemd units in
    `deploy/systemd/`;
  - the backend logs the CIDs it pins (`data/pins.jsonl`, no addresses).
  Tests: `backend/test/pins.test.js` (missing file reported with exit code 1, CAR with a wrong root
  refused, orphans: never the referenced ones, never with an incomplete list, never the recent ones;
  manifest; full CLI with simulated RPC and Kubo).
  Run on the server on 16 November: 9 CIDs referenced by the contract, 8 missing (uploaded at Pinata's
  time: collection metadata and the 3 vehicles', 2 collection images, 2 vehicle photos), all
  re-pinned; next check: all present. Daily check with automatic re-pin on
  (`mycarbook-check-pins.timer`).
  ⏳ Off-server backup: postponed by choice (few users). Until then the files are on the own node and
  on Pinata (not to be closed before the backup). The backup holds vehicle records with plate/VIN: the
  destination must be private.
  ⏳ LUKSO's fallback gateway stays in the frontend and in the CSP as a safety net; it can be removed
  after a period without missing files.
- ✅ **MCB-11 — Vehicles "pushed" by third parties, list breaking, no transfer** (Low).
  Present at e38be66: `frontend/index.html:973-1003` (an error on one token stopped the whole list),
  `:1110-1112` (`.replace` on an icon that is not a string), ABI without `transfer`
  (`config.js:22-34`), `how-it-works.html:199`.
  Done: defensive reading of each token (`js/lib/metadata.js`), a malformed token is skipped or shown
  without a name; "Hide from my list" (local preference) with "Show hidden vehicles"; "Transfer to the
  buyer" with LSP8 `transfer(…, force=false)` (only to UPs or contracts accepting LSP8), address
  validated.
  📌 Preventing unsolicited sends (`force=true`) would need a new contract: accepted (no transfer on
  the contract so far).
  Tests: `tests/e2e/xss-csp.test.mjs` (a malformed token does not break the list),
  `tests/e2e/flows.test.mjs` (hide/show; transfer: invalid, own or contract address refused, then
  `force=false`), `tests/frontend/logic.test.mjs`.
- ✅ **MCB-12 — Wrong mileage permanent; self-declared data presented as verified** (Low).
  Present at e38be66: `contracts/MyCarBookV2.sol:150-152`; `how-it-works.html:216/281`.
  Done: mileage only whole numbers up to 2,000,000; a jump of more than 100,000 km over the highest
  recorded needs an explicit confirmation; in the detail view "Data entered by the vehicle's owners,
  not verified by anyone"; texts without "tamper-proof". 📌 An on-chain limit, mileage correction and
  a "same VIN on other tokens" warning: new contract or indexer.
  Tests: `tests/e2e/flows.test.mjs` (out-of-range mileage refused; large jump without confirmation: no
  transaction), `tests/frontend/logic.test.mjs`.
- ✅ **MCB-14 — History read again from the start at every view** (Low).
  Present at e38be66: `frontend/index.html:1489-1532`, reload at language switch `:814`, after each
  entry `:1687`.
  Done: incremental reading with a per-session memory (`js/lib/log-cache.js`): the language switch
  redraws without reading, after a new entry only the new blocks are read. ⏳ The first opening still
  reads from the deployment block (an indexer: to evaluate).
  Tests: `tests/e2e/flows.test.mjs` (language switch: zero `eth_getLogs`),
  `tests/frontend/logic.test.mjs`.

## Dependencies and build

- ✅ **MCB-16 — Third parties (Google Fonts, jsDelivr, esm.sh) without SRI or CSP** (Info).
  Present at e38be66: `frontend/index.html:28-33`, `:537`; `admin-collection.html:8`, `:66`;
  `how-it-works.html:25-27`.
  Done: fonts (Oswald, Inter, JetBrains Mono, latin/latin-ext) in `frontend/fonts/`, ethers 6.13.4 (the
  same npm file) and erc725.js 0.28.2 (ESM bundle) in `frontend/vendor/`, fingerprints in
  `vendor/SHA256SUMS`, `integrity` on the scripts, rebuilt with `cd tests && npm run vendor`. Only
  LUKSO's fallback gateway (MCB-17) and the RPC of the user's UP extension remain. ⏳ The backend still
  uses LUKSO's public RPC (`RPC_URL_42` to point to ChainIntegrate's own node).
  Tests: in Chromium no request outside the site and the two gateways; fonts loaded; fingerprints and
  `integrity` checked (`static-checks`).
- ✅ **MCB-15 — Root `package.json` overwritten, `ethers` missing in the backend** (Info).
  Present at e38be66: `package.json` = the backend's manifest (since `7aea9a5`),
  `backend/package.json:10-16` without `ethers` and with "Proxy verso Pinata".
  Done: the Hardhat manifest restored (`b55890c`): `npm ci` at the root matches the lockfile again; the
  contract compiles (solc 0.8.27, 0 errors). `backend/package.json` with `ethers`, updated
  description, test script.
- ➖ **Root dev dependencies** (109 advisories, Hardhat tooling only, not deployed): not touched.
  `tests/` (development only): `ws` through ethers/jsdom on the Node side, not in the files served to
  the browser.

## Release

Release of 16 November 2026 on the server (details in [OPERATIONS.md](OPERATIONS.md)); pull request
numbers are MyCarBook's:

1. ✅ code updated to `main` (merge of PR #1);
2. ✅ backend: `npm ci` (0 vulnerabilities), new variables in `.env` (`IPFS_API_URL`, `AUTH_DOMAIN`,
   `ALLOWED_CHAIN_IDS=42`, `TRUST_PROXY`, `ADMIN_UP_ADDRESS`), PM2 restart; `/api/health` OK;
3. ✅ Nginx vhost: header snippet included only in MyCarBook's block (the other sites of the shared
   file unchanged), `X-Forwarded-For`, service files answer 404. CSP checked first in Report-Only with
   the UP extension (no violation), then enforced;
4. ✅ files re-pinned on the node and daily check on (MCB-17);
5. ✅ `ADMIN_SIGNER_ADDRESS=any` (PR #2): admin uploads on for the owner UP from any of its controllers
   with the SIGN permission;
6. ✅ privacy policy (`privacy.html`, PR #4) online;
7. ✅ technical logs kept at most 30 days, as the policy says: Nginx already rotates its logs (14 days,
   Ubuntu default); PM2 logs with `pm2-logrotate` (OPERATIONS.md, §5);
8. ✅ guide on www.chainintegrate.it updated;
9. ✅ security headers on the gateway `ipfs.chainintegrate.it` (MCB-10 / GEN-03), CSP first in
   Report-Only then enforced (PR #5);
10. ⏳ off-server backup (postponed).
