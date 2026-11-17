# MyCarBook — server operations

How to release and maintain the fixes of the November 2026 audit ([AUDIT.md](AUDIT.md)) for
**MyCarBook V2**. Example paths: adapt them to the server.

## 1. Backend

```bash
cd /var/www/mycarbook/backend
npm ci --omit=dev
```

Variables in `backend/.env` (see `backend/.env.example`):

| Variable | Value |
|---|---|
| `IPFS_API_URL` | the node's Kubo API (required, no default any more) |
| `IPFS_API_AUTH` | optional, the `Authorization` header when `API.Authorizations` is on in the node |
| `AUTH_DOMAIN` | `mycarbook.chainintegrate.it` |
| `ALLOWED_CHAIN_IDS` | `42` |
| `ADMIN_UP_ADDRESS` | the contract's owner UP (today `0x4a2605796e0d91A9667d6E30365aEEC384C48c27`) |
| `ADMIN_SIGNER_ADDRESS` | `any` (any controller of the owner UP with the SIGN permission), or the address of a single controller key; empty = admin disabled |
| `TRUST_PROXY` | `loopback` (default) |

Admin signature: with `ADMIN_SIGNER_ADDRESS=any` (the production choice) the owner UP's signature
from any device is enough, that is from any of its controllers with the SIGN permission, checked
on-chain by the KeyManager. To restrict it to one device, give the address of its controller key; to
find it, on the site connected with the owner UP, in the console:

```js
const s = await new ethers.BrowserProvider(window.lukso).getSigner();
const msg = "MyCarBook: admin key check";
console.log(ethers.verifyMessage(msg, await s.signMessage(msg)));
```

When the contract's ownership moves: update `ADMIN_UP_ADDRESS` and restart.

```bash
sudo pm2 restart mycarbook-backend
curl -s https://mycarbook.chainintegrate.it/api/health
```

Per-IP rate limit check: the PM2 logs must not show `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` warnings.

## 2. Frontend and Nginx

1. Copy `frontend/` (with `js/`, `css/`, `vendor/`, `fonts/`). In production the repository is
   cloned on the server and Nginx serves `frontend/` directly: `git pull` is the release.
2. `sudo cp deploy/nginx/security-headers.conf /etc/nginx/snippets/mycarbook-security-headers.conf`
3. Compare the vhost with `deploy/nginx/mycarbook.conf`: the snippet's `include` in the `server`
   block and in every `location` with its own `add_header`; in `location /api/`
   `proxy_set_header X-Forwarded-For $remote_addr;`. In production the vhost is one block of a
   file shared with other sites: change only that block.
4. **Phase 1**: in the snippet rename `Content-Security-Policy` to
   `Content-Security-Policy-Report-Only`, `sudo nginx -t && sudo systemctl reload nginx`, use the app
   with the UP extension (connection, mint with photo, entry with document, language switch, admin
   page) and check that the console (F12) shows no violations.
5. **Phase 2**: restore `Content-Security-Policy`, reload Nginx.

Check: `curl -sI https://mycarbook.chainintegrate.it/ | grep -i -E 'content-security|nosniff|referrer|frame'`.

The served libraries are rebuilt with `cd tests && npm ci && npm run vendor` (it updates
`vendor/SHA256SUMS`; if the files change, update the `integrity` attributes in the HTML: a test
checks it).

## 3. IPFS node: re-pin, check, clean-up, backup (MCB-17)

From the backend's server (it needs the Kubo API):

```bash
cd /var/www/mycarbook/backend
node scripts/check-pins.js --verbose     # lists the CIDs and the missing ones
node scripts/check-pins.js --repin       # re-pins the missing ones
node scripts/check-pins.js               # must say: all files are pinned on the node
```

`--repin` first tries `pin/add` from the IPFS network, then downloads a CAR from the fallback gateway
(`GATEWAY_FALLBACKS`, default `api.universalprofile.cloud`) and imports it with `dag/import`; Kubo
checks every block against the CID. The node's gateway has `Gateway.NoFetch=true`, but `pin/add`
through the API is not affected. (The script's messages are in Italian.)

Orphan pins (mints or entries cancelled after the upload):

```bash
node scripts/check-pins.js --gc-orphans          # list
node scripts/check-pins.js --gc-orphans --apply  # removal (only > 48 h, only if the CID list is complete)
```

Timers (adapt user and paths in the units; in production they run as `ubuntu`):

```bash
sudo cp deploy/systemd/mycarbook-*.service deploy/systemd/mycarbook-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mycarbook-check-pins.timer
```

State on 16 November 2026: the files pinned at Pinata's time were re-pinned and the daily check is on.

Off-server backup (postponed): set `BACKUP_REMOTE` in `.env` (e.g. `rclone:b2:mycarbook-ipfs` or
`rsync:backup@other-host:/srv/mycarbook`) and optionally `BACKUP_DIR`, `KEEP_LOCAL`, then enable
`mycarbook-ipfs-backup.timer`. Restore: `ipfs dag import <file>.car` for every file of the manifest
(the resulting CID is the same). The backup holds vehicle records with plate and VIN: the destination
must be private. Until it exists, the Pinata account must not be closed.

Once no file has been missing for a while, LUKSO's fallback gateway can be removed from
`frontend/js/lib/ipfs.js` and from the CSP.

## 4. Infrastructure still open

- Server → IPFS node link: WireGuard/SSH tunnel or TLS + `API.Authorizations` (Kubo ≥ 0.25), then
  `IPFS_API_AUTH` (MCB-13). Accepted risk for now: only files meant to be public travel on it.
- Gateway `ipfs.chainintegrate.it`: headers applied on 16 November 2026
  (`deploy/nginx/ipfs-gateway-headers.conf`, in the HTTPS `server` block of
  `/etc/nginx/sites-available/ipfs-gateway` on the node's server). Every change must be tried in
  Report-Only first, because the gateway is shared with the other apps; when the first plain PDF is
  opened straight from the gateway, check that it shows (MCB-10).
- Node: consider `Reprovider.Strategy=pinned` (MCB-06).
- Backend: `RPC_URL_42` pointing to ChainIntegrate's own LUKSO node (MCB-16).

## 5. Log retention (at most 30 days)

The privacy policy (`frontend/privacy.html`, section 5) says the server's technical logs are kept at
most 30 days.

- Nginx: rotated by logrotate (Ubuntu default: 14 days); check with
  `grep -E "rotate|daily|weekly" /etc/logrotate.d/nginx`.
- PM2 (`/root/.pm2/logs/`): without rotation they grow forever. Once, on the server (it applies to
  every root PM2 process), done on 16 November 2026:

```bash
sudo pm2 install pm2-logrotate
sudo pm2 set pm2-logrotate:rotateInterval '0 0 * * *'
sudo pm2 set pm2-logrotate:retain 30
sudo pm2 set pm2-logrotate:max_size 100M
sudo pm2 set pm2-logrotate:compress true
sudo pm2 save
```

  To clear MyCarBook's old logs at once: `sudo pm2 flush mycarbook-backend`.

## 6. Deploying the MyCarBook Service contracts

`scripts/deploy-service.js` deploys `ServiceRegistryFactory` and `VehicleRegistry`, links them, sets the
arbiter if given, writes `LSP4Creators[]` naming ChainIntegrate's Universal Profile on the vehicle
registry, and hands ownership of both to that profile. Testnet first.

On the server (a clone of this repository):

```bash
cd /var/www/mycarbook-service && git pull --ff-only origin main && npm ci && npm test
```

A new key, used only to pay the deployment (it keeps no power afterwards): create it on the server, fund
it with a little LYX (testnet: LUKSO's faucet), and keep it out of the shell history (a leading space
with `HISTCONTROL=ignorespace`, or a `.env` readable only by its user):

```bash
node -e 'const w=require("ethers").Wallet.createRandom();console.log(w.address);console.log(w.privateKey)'
```

```bash
 DEPLOYER_KEY=0x… OWNER_UP=0x… ARBITER=0x… npm run deploy:testnet
```

It prints the addresses and writes `deployments/luksoTestnet.json` (commit it). On mainnet:
`npx hardhat run --network luksoMainnet scripts/deploy-service.js` with `CONFIRM_MAINNET=yes`.

Afterwards, from ChainIntegrate's Universal Profile:
- add the vehicle registry to `LSP12IssuedAssets[]`, so that Universal Everything shows ChainIntegrate as
  a verified creator;
- set the arbiter (`setArbiter`) if it was not given;
- create the first business register with `createRegistry` on the factory.

Verification of the source on LUKSO's explorer: `npx hardhat verify --network luksoTestnet <address>
<constructor arguments>` (the factory: the deployer's address; the vehicle registry: name, symbol,
deployer, factory).
