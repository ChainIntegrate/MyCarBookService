# MyCarBook — data inventory and reduction proposal

Reference: audit findings MCB-05 / MCB-06 ([AUDIT.md](AUDIT.md)). State of the code after the fixes
of 16 November 2026; the MyCarBookV2 contract is unchanged. This document describes **V2**; the new
version's data model is in `docs/DESIGN.md`.

## 1. Where each piece of data goes

### On the LUKSO chain (public, permanent, deletable by no one)

| Data | Where | Written by | Notes |
|---|---|---|---|
| Owner's UP address ↔ vehicle | `Transfer`, `VehicleMinted(owner)`, `tokenOwnerOf` | mint / transfer | the UP often has a name and picture (LSP3) |
| Registration date, ownership date, mileage at mint | `vehicleInfo` storage, `VehicleMinted` event | mint | cannot be changed |
| Highest recorded mileage | `vehicleInfo.km` storage | every entry | only goes up |
| For each entry: date, mileage, categories, amount (cents), free description up to 280 bytes, address of who logged it (`loggedBy`) | `InterventionLogged` event | current owner | the description may hold personal data typed by the user; the document link is appended to it |
| Fingerprint (keccak256) and `ipfs://` link of the vehicle record | `TokenIdDataChanged` / `getDataForTokenId(LSP4Metadata)` | mint; contract owner with `setDataForTokenId` | earlier versions stay in the events too |

### On IPFS (public to whoever knows the CID; the CID is on the chain)

| Data | File | Notes |
|---|---|---|
| Vehicle name, brand, model, trim, **plate**, **VIN** | LSP4Metadata JSON | plate and VIN optional; pinned on ChainIntegrate's node, announced to the IPFS network, possible copies on third-party gateways |
| Vehicle photo | image | re-encoded in the browser: no EXIF/GPS (the backend refuses images with metadata) |
| Entry document (invoice, etc.) | image or PDF | images cleaned; **PDFs uploaded as they are** (author, software, etc.) and with their content visible (addresses, names) |

### On ChainIntegrate's server (not public)

| Data | Where | Retention |
|---|---|---|
| IP address | Nginx logs; rate-limit memory (15 min) | Nginx logs: 14 days (logrotate); PM2 logs: 30 days (pm2-logrotate) |
| Upload signature and UP address | in memory only, during the check; used nonces for about 6 min | not stored |
| Pinned CIDs, purpose, time (no address) | `backend/data/pins.jsonl` | as long as the orphan clean-up needs it |
| Manual photo access list | `backend/allowed-addresses.json` | managed by hand |

### Third parties

- The user's Universal Profile extension or app, and its LUKSO RPC.
- Gateway `api.universalprofile.cloud`: only for files not on ChainIntegrate's node (a fallback since
  the re-pin of 16 November 2026, MCB-17).
- Backend: LUKSO's public RPC, to check signatures and the membership tier.
- **No longer**: Google Fonts, jsDelivr, esm.sh (everything is served from ChainIntegrate's domain).

## 2. Notices at the moment the user writes (done)

- Plate/VIN: a box next to the fields ("optional, public and permanent, linkable to your UP, leave them
  empty if you don't need them") and a required acknowledgement check box when either is filled.
- Entry description: a notice under the field (public, permanent, don't write names or addresses).
- Photo: public/permanent notice and automatic removal of metadata.
- Document: public/permanent notice, advice not to attach personal data, a note that PDFs may hold
  hidden data.
- First screen and "How it works": corrected text, list of public data, "Who can change what".

## 3. Proposal to reduce personal data

Without a new contract (app and backend only):

1. **Plate and VIN no longer in clear by default.** Proposal: the VIN field stores only the last 6
   characters (enough for a buyer to compare with the registration document), or a fingerprint
   `keccak256(normalised VIN + tokenId)` checkable by whoever has the VIN; the plate not stored (it
   changes with re-registration and identifies the owner). To decide: usefulness at resale versus
   exposure.
2. **Documents**: accept only (cleaned) images, or convert PDFs to images in the browser (pdf.js)
   before the upload; alternatively strip PDF metadata on the server (qpdf) before pinning.
3. **Free description**: detect phone numbers, e-mails, tax codes, IBANs in the browser and ask for
   confirmation before signing.
4. **Amounts**: make them explicitly optional (they already are) and allow ranges instead of the
   exact figure in the statistics.
5. **IPFS node**: `Reprovider.Strategy=pinned` (or no announcing) to avoid advertising the CIDs on the
   network; a written procedure to stop serving a file at the data subject's request (unpin + check).
6. **Nginx logs**: short retention (e.g. 14 days) and truncated IPs.

With a new contract (now the new version of this repository, see `docs/DESIGN.md`):

7. Vehicle record changeable only by the token's owner (rectification), no rewriting by the contract
   owner (MCB-04).
8. Identifying data off the chain and off public IPFS, shared with a buyer on request (e.g. encrypted
   with a key the seller hands over), with only a fingerprint on-chain.

## 4. Privacy policy

Published in [`frontend/privacy.html`](../frontend/privacy.html) on 16 November 2026, with the same
structure as the ChainIntegrate Account policy (up-onboarding repository): same controller, contacts,
log retention (at most 30 days) and rights. When the processing changes (new fields, backup, third
parties), the page, its date and this document must be updated together. It covers:

- the controller and contacts (info@chainintegrate.it);
- purposes: keeping the logbook the user chose; storing the files on IPFS; checking permissions
  (membership);
- legal bases: performing the service requested (Art. 6.1.b GDPR), legitimate interest in security
  (Art. 6.1.f);
- the data processed and where: section 1;
- the public and permanent nature of on-chain data; what can be removed (pins on ChainIntegrate's node,
  logs) and what cannot (the chain, other people's copies);
- recipients and third parties: section 1, "Third parties";
- retention: section 1;
- rights and how to exercise them, the removal procedure on the node;
- the date of the last update.
