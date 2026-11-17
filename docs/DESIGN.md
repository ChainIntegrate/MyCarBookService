# Design — MyCarBook Service

Status: **draft, before any code** (17 November 2026). It records the decisions taken so far and the
points still open. The current product, **MyCarBook V2** (live on LUKSO mainnet), is described in the
[README](../README.md) and its audit in [AUDIT.md](AUDIT.md); this document is about the next version.

## 1. The problem

A car's history is scattered: paper logbooks get lost, workshops keep their own records, dealers and
manufacturers have theirs, and a buyer cannot tell what is true. MyCarBook V2 solved part of it for the
owner (a personal logbook on-chain), but with three limits accepted in its audit:

- the history is **self-declared**: nobody attests it, and a dishonest seller can start a clean
  history for the same car (MCB-12);
- identifying data (plate, VIN) and descriptions are **public and permanent** (MCB-05);
- the contract's owner can rewrite any vehicle's record, and the owner of the car cannot correct it
  (MCB-04).

MyCarBook Service keeps the free personal logbook and adds what makes a history worth something at
resale: **records attested by the people who work on the car** (workshops, body shops, tyre shops,
dealers, manufacturers), private by default and shown with the owner's consent.

It must work whichever side adopts it first: a single owner, a workshop on its own, a dealer network
or a fleet. It is a product that may be sold or white-labelled.

## 2. Principles

- **Two kinds of entry, never confused.** "Declared by the owner" and "recorded by a verified
  business" are different things, shown differently, stored in different contracts.
- **One way in.** People and businesses use the **ChainIntegrate Account** (up-onboarding): a
  Universal Profile that belongs to them, created with an invitation code, with ChainIntegrate paying
  the operations. Nobody needs LYX, a crypto wallet or crypto words.
- **One register per business**, as in GasTrace: ChainIntegrate creates it through a factory; the
  register belongs to the business; ChainIntegrate has no power inside it.
- **Proofs on-chain, personal data off it.** The chain holds identifiers that reveal nothing,
  fingerprints, dates and who attested what. Plate, VIN, descriptions, amounts, documents and photos are
  encrypted, on ChainIntegrate's IPFS node, and readable only by whoever holds the key.
- **The platform is the value, not a lock.** The contracts are open: anyone may call them, from
  Blockscout too. What a business or a person pays for is the platform: the app, the files on
  ChainIntegrate's node, the vehicle identifier, the attestations, sharing, the relayer.
- **Usable from a phone.** Owners and workshop staff mostly have a phone in hand (section 8).
- **Fixes of the V2 audit built in**, not added later: signed and single-use uploads, strict schemas,
  CSP, no inline code, files checked by their bytes, no owner power over records.

## 3. Who does what, and what it costs

| Who | With what | Does | Price |
|---|---|---|---|
| **An owner** (private person) | ChainIntegrate Account (extension, or phone — section 8) | Registers up to **10 vehicles**, keeps a personal logbook, sees the attested records of their cars, shares the history with a buyer, transfers the car | **First price**: the invitation code for the account. The logbook itself is free. |
| **A business** (workshop, body shop, tyre shop, dealer, manufacturer, fleet) | Its ChainIntegrate Account (owner of its register) and the business panel | Records services and inspections on vehicles; a dealer or manufacturer may also issue the vehicle token; manages its staff | **Second price**: the **MyCarBook Service authorization**, i.e. ChainIntegrate creates its register. Optional plans (storage, statistics, volumes, API) are limits of the service, not of the contract. |
| **A business's staff** | A phone (or computer) key, authorized by the business | Records services for the business | Included in the business's authorization |
| **A buyer, an appraiser, an insurer** | A share link (no account needed) | Reads what the owner chose to show, checks it against the chain | Free |
| **The relayer** | ChainIntegrate's server | Checks and sends signed operations, pays the gas, applies limits and suspensions | — |
| **ChainIntegrate** | Its Universal Profile (factory owner), the account service, the backend | Creates business registers, computes vehicle identifiers, pins files, verifies businesses | — |

The ChainIntegrate Membership used by V2 is **not used** by the new version: the account and the
service authorization replace it.

### 3.1 Open contracts, limits on the platform (decision of 17 November 2026)

- Anyone can create vehicles on the vehicle contract, directly, paying their own gas. Nothing is lost:
  such a vehicle has no identifier issued by ChainIntegrate (section 4.1), no files on ChainIntegrate's
  node, no attestations, and the app shows it as **not verified**.
- The **10 vehicles per account** limit is applied by the platform (backend and relayer), not by the
  contract, where it could be bypassed with free new addresses.
- The backend pins files only for ChainIntegrate Accounts (checked with the account service) and within
  the limits; the relayer pays only for them.
- Terms of service: the free logbook is for personal use. On abuse, ChainIntegrate stops serving the
  account (relayer and backend), without touching its data.

### 3.2 Business registers (decision of 17 November 2026)

- One register per business (not per network). A dealer network with several sites is one register per
  company, each site's staff as operators; a network-level view is a service feature.
- The business's **role** (workshop, body shop, tyre shop, dealer, manufacturer, fleet, inspection
  centre…) is written when the register is created and is public: it is what gives an attestation its
  weight.
- **Suspension** (unpaid renewal, dispute): the factory records the register's status; the relayer and
  the backend stop serving it. Its records stay, and the explorer shows "suspended since…". As in
  GasTrace, ChainIntegrate can stop serving a register, never change what is inside it.
- A register is an on-chain contract, not a web domain: one site and one app serve every register. A
  white-label customer may get its own sub-domain pointing to the same app with its branding.

## 4. Data

### 4.1 Vehicle identity

- **The VIN is never on-chain, not even hashed.** `keccak256(VIN)` can be reversed by trial: for a known
  make, model and year only the plant and serial number are unknown, a few million candidates; and the
  VIN is printed on the windscreen and in used-car ads. With a plain hash, anyone knowing a VIN would
  read that car's history forever.
- On-chain the vehicle is a **`vehicleId`**: an opaque identifier computed by ChainIntegrate's service,
  `HMAC-SHA256(serviceKey, normalised VIN)` (normalised: upper case, no spaces, the 17 VIN characters,
  check digit verified where it applies). Same VIN, same `vehicleId`, for every business and owner, so
  records aggregate; without the service key, nobody can go from a VIN to a history.
- The service computes a `vehicleId` only for authenticated platform users and rate-limits it, so that
  the service itself cannot be used as an oracle to enumerate VINs.
- The **plate** is never stored as an identifier (it changes and identifies the owner through the
  public vehicle register); it may be stored, encrypted, as data of the vehicle.
- The service key is a critical secret: kept off the code, backed up off the server, rotation planned
  (an old `vehicleId` stays valid; a new one would need a mapping, see section 10).

### 4.2 The vehicle token (personal side)

- One LSP8 token per vehicle in the **vehicle registry**, held by the current owner's account.
- Issued by anyone: the owner, or a dealer or manufacturer (from their register's account). The token
  records **who issued it and with which role**; one issued by a verified dealer or manufacturer counts
  more than one created by a private person.
- **One verified vehicle per `vehicleId`.** A private token does not lock the VIN: a token issued by a
  verified business, or a claim proven to ChainIntegrate (the registration document), takes precedence,
  and the private token is marked as superseded in the history. A token issued by a verified business
  cannot be displaced by a private one. Disputes are handled by ChainIntegrate with a documented
  procedure.
- **Transfer in two steps** (offer, accept): no more vehicles pushed into someone else's account (V2
  MCB-11).
- **No owner power over records.** The contract owner cannot rewrite a vehicle's data (V2 MCB-04). The
  vehicle's owner can update their own (encrypted) vehicle record; each version stays in the history.
- Registration date, ownership date and starting mileage are part of the encrypted record, not public
  storage.

### 4.3 Owner entries (personal logbook)

- What V2 has, encrypted: date, mileage, categories, amount, description, attached document.
- On-chain: the `vehicleId`, a fingerprint of the encrypted entry, the time, the owner's account and the
  categories bitmask (same values as V2, so statistics need no conversion). Whether categories and
  mileage should be public is an open point (section 11).
- Mileage: whole numbers up to 2,000,000; a large jump needs an explicit confirmation (as in V2).

### 4.4 Professional records (business side)

- **One record = one LSP8 token in the business's register**, held by the business and **not
  transferable**: it is the business's professional receipt and does not follow the car at resale (the
  history does, through the `vehicleId`).
- On-chain: `vehicleId`, the business (its register), who signed (the operator), date, categories,
  a fingerprint of the encrypted content, and the mileage **read** at the service (see below).
- Encrypted (register's data key, section 5): description, parts, amount, documents, photos.
- **Adoption the other way round**: a business records services on a `vehicleId` even when the car's
  owner is not on MyCarBook. The records are there, encrypted, and become readable by the owner when
  they claim the vehicle (section 5.3).
- **Mileage readings**: a reading lower than an earlier attested one is not refused but **flagged** in
  the history (odometer roll-back is what buyers fear most).
- Corrections: a record is never changed; a correcting record refers to the one it replaces (as
  GasTrace's planned "Correct" and Supplier's `supersedes`).

### 4.5 Files

- On ChainIntegrate's IPFS node only, pinned by the backend: vehicle records, entries and records
  (encrypted JSON), photos and documents (encrypted).
- Photos re-encoded in the browser or app (no EXIF/GPS) before encryption; PDFs: see open points.
- Every upload signed by the account (content fingerprint, single-use nonce, domain, network), strict
  schema, type checked by its bytes: the V2 fixes, reused.

### 4.6 What the chain reveals

Even with everything encrypted, public metadata says something. It must be listed in the privacy
policy and in "How it works":

- that a `vehicleId` exists, how many entries and records it has and when;
- which business recorded something on it, and its role (a workshop's customer base is visible as a
  list of opaque identifiers and dates);
- which account holds a vehicle token (the account may carry a name and picture);
- categories and mileage, if kept public (open point).

Mitigations to evaluate: an owner may hold vehicles in an address separate from their main profile;
categories and mileage only encrypted; batching. As in GasTrace §4.5, they are documented first and
implemented if needed.

## 5. Encryption and sharing

Built on what Supplier Trust Registry and GasTrace already do (encrypted JSON on IPFS, data keys,
single-use share keys).

### 5.1 Keys

- **Vehicle key**: one symmetric key per vehicle, created by the owner's app, used for the owner's
  vehicle record and entries. Wrapped (encrypted) for the owner's account devices.
- **Register data key**: one per business register, as in GasTrace §5; held by the business's
  authorized devices; used for its records.
- **Record key**: each professional record is encrypted with its own key, stored wrapped under the
  register's data key. This lets the business hand over a single record (or all the records of one
  `vehicleId`) without giving its register key.

### 5.2 Who reads what

| Reader | Reads | How |
|---|---|---|
| The owner | their vehicle record and entries; every record any business made on their `vehicleId` | vehicle key; record keys handed over at the claim (5.3) and at each new record while the vehicle is claimed |
| The business | its own records | register data key |
| Another business | only what the owner shares with it (e.g. the next workshop sees the past services) | a share (5.4) |
| A buyer, appraiser, insurer | what the owner shares | a share link |
| ChainIntegrate | the identifiers and public metadata; **not** the content | holds no data key; it holds the service key for `vehicleId` |

### 5.3 Claiming a vehicle

When an owner registers a vehicle (or receives it), the platform finds the records already made on its
`vehicleId`. The businesses' apps hand over the record keys, wrapped for the vehicle key: automatically
for future records once the vehicle is claimed, and for past records with a rule chosen by each business
(automatic, or on confirmation). How a business confirms the owner is really the owner (the registration
document, the car in the workshop) is an open point.

### 5.4 Sharing

- A **share link** (Supplier's pattern): a one-time key in the part of the URL the browser never sends
  to a server (`#…`); the shared content is re-encrypted with it; on-chain only a reference and a
  fingerprint, never the key. The reader's page checks everything against the chain before showing it.
- The owner chooses what to share: the whole history, a period, without amounts, without documents.
- At sale, the history goes with the `vehicleId`; the seller's personal entries can be handed over or
  not (the seller's choice); the professional records are re-wrapped for the buyer's vehicle key.

### 5.5 Deletion

Data on the chain cannot be deleted; encrypted content becomes unreadable when its keys are destroyed
(crypto-shredding). The app offers "delete my data": the vehicle key is destroyed on the owner's devices,
files are unpinned from ChainIntegrate's node. Whether this satisfies an erasure request is debated:
the privacy policy says so plainly, and a legal opinion is needed before real use.

## 6. Contracts

On LUKSO (LSP8, LSP4, ERC-1271 for accounts), Solidity 0.8.x, not upgradeable, verified on LUKSO's
explorer. Package versions and LSP8 constructor aligned to those already used (`MyCarBookV2.sol`,
GasTrace). Deployed first on testnet, with a **new key** with no permission on ChainIntegrate's
Universal Profile.

### 6.1 `VehicleRegistry` (personal side, open)

- LSP8, one token per vehicle; `mint(vehicleId, issuerRole, recordRef)` open to anyone; issuer and role
  recorded; the platform's notion of "verified" comes from the issuer being a register of the factory.
- `offerTransfer` / `acceptTransfer`; no `force` push.
- `updateRecord(tokenId, recordRef)` only by the token's owner; versions kept as events.
- `logEntry(tokenId, entryRef, categories, …)` only by the token's owner.
- `markSuperseded(tokenId, byTokenId)` for the precedence rule (section 4.2): who may call it is an open
  point (a verified issuer's token, or ChainIntegrate after a dispute).
- No `setDataForTokenId` for the contract owner on vehicle records; `renounceOwnership` disabled.

### 6.2 `ServiceRegistryFactory`

- Owned by ChainIntegrate's Universal Profile; `createRegistry(owner, role, name, …)` deploys an
  EIP-1167 clone; `isRegistry(address)`, `roleOf(registry)`, `statusOf(registry)` (active, suspended
  since) for the relayer, the backend, the app and the explorer.
- No rights inside a register.

### 6.3 `ServiceRegistry` (one per business)

- LSP8 collection owned by the business's account; tokens = records, **not transferable**.
- **Operators**: staff devices or accounts, authorized by the owner.
- **Writes are signed operations** (EIP-712, as GasTrace): `recordService(payload, signer, nonce,
  deadline, signature)` by the owner or an operator; anyone may submit, the signature decides. Unordered
  nonces, a maximum validity checked by the contract, a way to cancel an unsent signature (GasTrace
  review G-07, built in from the start).
- Owner operations (operators, data-key wraps, metadata, ownership transfer in two steps) accepted only
  from an **administrator** key of the owner's account, not from any SIGN key (GasTrace review A01,
  built in).
- Optionally `issueVehicle(…)` for dealers and manufacturers, which mints in `VehicleRegistry` with the
  register as issuer.
- Inputs checked: categories limited to defined bits, mileage bounded, dates not in the future beyond a
  tolerance.

### 6.4 What the contracts do not do

- No payment, no membership, no tier: prices and plans are on the platform.
- No VIN, plate or personal data in any form.

## 7. Backend and relayer

Starting from MyCarBook V2's backend (already hardened) and GasTrace's relayer.

- **Account check**: a request comes from a ChainIntegrate Account (asked to the account service),
  within the 10-vehicle limit for private accounts, or from an operator of an active register.
- **`vehicleId` service**: computes the HMAC from a VIN for authenticated users, rate-limited, logs no
  VIN.
- **Pinning**: signed, single-use, content-bound uploads; strict schemas for every JSON type; files by
  their bytes; ledger of pins for orphan clean-up; daily pin check and off-server backup (V2 tools).
- **Relayer**: accepts only the platform's contracts and registers of the factory, simulates first,
  limits per account and per register per day, refuses suspended registers, keeps a journal.
- **API for businesses' software** (workshop management systems): create a record from their own system
  with a key authorized as operator. Likely the strongest adoption lever; at least designed from the
  start, built when a first business needs it.
- Logs: at most 30 days, no content, no VIN.

## 8. Clients and the phone

**Requirement (17 November 2026): the whole service must be usable from a phone.**

| Who | Need on the phone |
|---|---|
| An owner | open the logbook, add an entry, scan a document, share the history with a buyer at the car, receive a vehicle |
| Workshop staff | at the car: scan the VIN (windscreen label, registration document), read the mileage, record the service, take photos, often offline |
| A buyer | open a share link: works in any browser, no app, no account |

### 8.1 Options

1. **ChainIntegrate Account app for Android (and later iOS)**: the phone version of the extension,
   already designed in up-onboarding (`android/README.md`: key in the Android Keystore with fingerprint
   or PIN, joining an existing account as a new device, same relay and catalog). It is the "simpler
   UP wallet" for the general public, separate from Cross_Chain's UP Wallet: to build in its own track.
2. **No app: the website on the phone** (a web app that can be added to the home screen), with the
   device's key kept in the browser and unlocked by the phone's biometrics (a passkey, through WebAuthn).
   Feasibility to check before deciding: a passkey's own key type is not the one LUKSO accounts use, so
   it would protect a separate key rather than sign directly; browser storage can be cleared (iOS in
   particular), so a backup copy stays mandatory; support of the needed WebAuthn features varies by
   phone. Attractive for owners who use the service rarely; a prototype will tell.
3. **WalletConnect to UP Wallet**, for people who already use LUKSO (as Supplier does).
4. **Workshop app**: GasTrace's model (Capacitor, phone key in the Android Keystore as the register's
   operator, VIN scanning, offline queue). Staff do not need an account of their own: their phone's key
   is an operator of the business's register, authorized by the owner.

Proposal: design the web app mobile-first and the signing layer pluggable (extension, phone app,
WalletConnect, possibly the no-app option), so that the clients can come in any order. Start with the
website on the phone for owners and buyers, the GasTrace-style app for workshops, and follow the
ChainIntegrate Account app's track for the general public.

## 9. Privacy and compliance

- **Roles under the GDPR**, to settle with an adviser before real use, because they change how the
  product is sold:
  - personal logbook: ChainIntegrate is controller (as in V2);
  - businesses: each is controller of the data it records about its customers; ChainIntegrate is
    processor for them (data processing agreement);
  - white-label sale: ChainIntegrate processor of the buyer.
- **Legal bases**: the service requested by the owner; for businesses, their contract with the customer
  and legal obligations; sharing only on the owner's consent.
- **What is public** (section 4.6) written in the privacy policy, in plain words, with a data
  protection impact assessment before real data.
- **Rights**: access, rectification (new versions, corrections), erasure within the limits of
  section 5.5, portability (export of the history).
- Vehicle data is personal data when linkable to a person (EDPB guidelines 01/2020 on connected
  vehicles): this is why no identifier on the chain can be computed from the VIN without the service.

## 10. From V2

- The 3 vehicles on V2's mainnet contract can be imported as "declared by the owner", with a reference
  to their V2 token and history; V2's plate and VIN stay public on V2 (they cannot be removed from
  there), the new record does not repeat them in clear.
- V2 stays live until its users have moved; its site then points to the new version.
- `vehicleId` and service-key rotation: if the key must change, a mapping from old to new identifiers
  signed by ChainIntegrate keeps the histories joined.

## 11. Open points

1. Categories and mileage public or encrypted? Public helps aggregate statistics and the roll-back
   check, encrypted protects better (section 4.6).
2. How a business checks that whoever claims a vehicle is its owner before handing over past records.
3. Who may mark a private vehicle token as superseded, and the dispute procedure.
4. PDFs: accept only images (cleaned) and convert PDFs in the app, or clean them on the server.
5. The no-app option on the phone (section 8.1, option 2): prototype before deciding.
6. Business API: format and authentication, and which management software first.
7. Legal: roles, DPIA, erasure through key destruction, terms of service (personal use of the free
   logbook, suspension).
8. Which sector first: owners, a workshop, a dealer with its workshop, a fleet. The design must not
   depend on the answer; the first pilot does.
9. The vehicle registry's `vehicleId` precedence when two verified businesses disagree.

## 12. Decisions

| Date | Decision |
|---|---|
| 16 Nov 2026 | No new contract for V2; the new version lives in this repository |
| 17 Nov 2026 | Onboarding only through the ChainIntegrate Account; no Membership |
| 17 Nov 2026 | Two prices: invitation (account), MyCarBook Service authorization (business register); plans on the platform |
| 17 Nov 2026 | One register per business, created by a factory (GasTrace's model) |
| 17 Nov 2026 | Free personal logbook, up to 10 vehicles per account, limit applied by the platform |
| 17 Nov 2026 | Open contracts: the value is the platform (files on ChainIntegrate's node, identifiers, attestations) |
| 17 Nov 2026 | Usable from a phone |
| 17 Nov 2026 | One repository for both sides (personal and business) |

Proposed in this draft, to confirm: opaque `vehicleId` computed by the service (section 4.1); content
encrypted and shown with the owner's consent (section 5); professional records as non-transferable
tokens in the business's register (section 4.4).
