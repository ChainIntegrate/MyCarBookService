// MyCarBook Service contracts (docs/DESIGN.md §6). Each requirement has a test that tries to get round
// it and checks it is refused.
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const ROLE = { WORKSHOP: 1, BODY_SHOP: 2, DEALER: 4, MANUFACTURER: 5 };
const STATUS = { None: 0, Active: 1, Superseded: 2, Conflict: 3 };
const ADMIN_PERMS = 0x7f3f06n; // up-onboarding's administrator key
const ACCESS_PERMS = 0x800n | 0x40000n | 0x200000n | 0x400000n; // up-onboarding's access key (SIGN included)
const DAY = 24 * 3600;

const id = (s) => ethers.id(s);
const ref = (s) => ethers.toUtf8Bytes(`ipfs://Qm${s}`);
const commit = (km, salt) => ethers.solidityPackedKeccak256(["uint256", "bytes32"], [km, salt]);

const TYPES = {
  RecordService: [
    { name: "signer", type: "address" },
    { name: "payloadHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  ShareRecordKey: [
    { name: "signer", type: "address" },
    { name: "recordId", type: "bytes32" },
    { name: "wrapHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  IssueVehicle: [
    { name: "signer", type: "address" },
    { name: "vehicleId", type: "bytes32" },
    { name: "contentHash", type: "bytes32" },
    { name: "recordRefHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  CancelNonce: [
    { name: "signer", type: "address" },
    { name: "cancelled", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  SetOperator: [
    { name: "operator", type: "address" },
    { name: "enabled", type: "bool" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  SetData: [
    { name: "dataKeys", type: "bytes32[]" },
    { name: "dataValuesHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  TransferOwnership: [
    { name: "newOwner", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  AcceptOwnership: [
    { name: "newOwner", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

let nonceCounter = 1n;
const nextNonce = () => nonceCounter++;

async function sign(wallet, registry, typeName, value) {
  const { chainId } = await ethers.provider.getNetwork();
  const domain = { name: "MyCarBookServiceRegistry", version: "1", chainId, verifyingContract: await registry.getAddress() };
  return wallet.signTypedData(domain, { [typeName]: TYPES[typeName] }, value);
}

async function deadlineIn(seconds) {
  return BigInt(await time.latest()) + BigInt(seconds);
}

async function fixture() {
  const [deployer, arbiter, stranger, privateA, privateB, buyer, relayer] = await ethers.getSigners();
  const adminKey = ethers.Wallet.createRandom();
  const accessKey = ethers.Wallet.createRandom();
  const staff = ethers.Wallet.createRandom();
  const workshopOwner = ethers.Wallet.createRandom();

  const Factory = await ethers.getContractFactory("ServiceRegistryFactory");
  const factory = await Factory.deploy(deployer.address);
  const Vehicles = await ethers.getContractFactory("VehicleRegistry");
  const vehicles = await Vehicles.deploy("MyCarBook Vehicles", "MCBV", deployer.address, await factory.getAddress());
  await factory.setVehicleRegistry(await vehicles.getAddress());
  await vehicles.setArbiter(arbiter.address);

  // The dealer's account: a Universal Profile with an administrator key and an access key.
  const UP = await ethers.getContractFactory("MockUniversalProfile");
  const dealerUp = await UP.deploy([adminKey.address, accessKey.address], [ADMIN_PERMS, ACCESS_PERMS]);

  const salt1 = id("dealer");
  const dealerAddr = await factory.predictRegistryAddress(salt1);
  await factory.createRegistry(salt1, await dealerUp.getAddress(), ROLE.DEALER, "Rossi Auto", "RSS");
  const dealer = await ethers.getContractAt("ServiceRegistry", dealerAddr);

  const salt2 = id("workshop");
  const workshopAddr = await factory.predictRegistryAddress(salt2);
  await factory.createRegistry(salt2, workshopOwner.address, ROLE.WORKSHOP, "Officina Bianchi", "OFB");
  const workshop = await ethers.getContractAt("ServiceRegistry", workshopAddr);

  // The workshop authorizes a staff phone (owner = an EOA key, signed operation sent by the relayer).
  {
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const sig = await sign(workshopOwner, workshop, "SetOperator", { operator: staff.address, enabled: true, nonce, deadline });
    await workshop.connect(relayer).setOperatorSigned(staff.address, true, nonce, deadline, sig);
  }

  return { deployer, arbiter, stranger, privateA, privateB, buyer, relayer, adminKey, accessKey, staff, workshopOwner, factory, vehicles, dealerUp, dealer, workshop };
}

async function payload(over = {}) {
  return {
    recordId: id(`record-${Math.random()}`),
    vehicleId: id("VIN-1"),
    serviceDate: BigInt(await time.latest()) - BigInt(DAY),
    kmCommitment: commit(120000, id("salt")),
    contentHash: id("content"),
    contentRef: ref("content"),
    corrects: ethers.ZeroHash,
    ...over,
  };
}

async function record(registry, signerWallet, p, opts = {}) {
  const nonce = opts.nonce ?? nextNonce();
  const deadline = opts.deadline ?? (await deadlineIn(3600));
  const payloadHash = await registry.hashPayload(p);
  const sig = await sign(opts.signWith || signerWallet, registry, "RecordService", { signer: opts.claimedSigner || signerWallet.address, payloadHash, nonce, deadline });
  return { tx: () => registry.recordService(p, opts.claimedSigner || signerWallet.address, nonce, deadline, sig), nonce, deadline, sig };
}

describe("ServiceRegistryFactory", () => {
  it("only ChainIntegrate creates registers; role and owner checked", async () => {
    const { factory, stranger } = await loadFixture(fixture);
    await expect(factory.connect(stranger).createRegistry(id("x"), stranger.address, ROLE.WORKSHOP, "X", "X")).to.be.revertedWith("Ownable: caller is not the owner");
    await expect(factory.createRegistry(id("y"), ethers.ZeroAddress, ROLE.WORKSHOP, "Y", "Y")).to.be.revertedWithCustomError(factory, "InvalidOwner");
    await expect(factory.createRegistry(id("z"), stranger.address, 0, "Z", "Z")).to.be.revertedWithCustomError(factory, "InvalidRole");
    await expect(factory.createRegistry(id("w"), stranger.address, 99, "W", "W")).to.be.revertedWithCustomError(factory, "InvalidRole");
  });

  it("suspension: only ChainIntegrate, recorded with its time, reversible; unknown registers refused", async () => {
    const { factory, workshop, stranger } = await loadFixture(fixture);
    const w = await workshop.getAddress();
    await expect(factory.connect(stranger).setSuspended(w, true)).to.be.revertedWith("Ownable: caller is not the owner");
    await expect(factory.setSuspended(stranger.address, true)).to.be.revertedWithCustomError(factory, "UnknownRegistry");
    await expect(factory.setSuspended(w, true)).to.emit(factory, "RegistrySuspended");
    expect(await factory.isActive(w)).to.equal(false);
    expect(await factory.suspendedSince(w)).to.be.greaterThan(0n);
    await expect(factory.setSuspended(w, true)).to.be.revertedWithCustomError(factory, "StatusUnchanged");
    await factory.setSuspended(w, false);
    expect(await factory.isActive(w)).to.equal(true);
  });

  it("vehicle registry set once; renounce disabled; registers listed", async () => {
    const { factory, vehicles, dealer, workshop } = await loadFixture(fixture);
    await expect(factory.setVehicleRegistry(await vehicles.getAddress())).to.be.revertedWithCustomError(factory, "VehicleRegistryAlreadySet");
    await expect(factory.renounceOwnership()).to.be.revertedWithCustomError(factory, "RenounceDisabled");
    expect(await factory.registries(0, 10)).to.deep.equal([await dealer.getAddress(), await workshop.getAddress()]);
    expect(await factory.roleOf(await dealer.getAddress())).to.equal(ROLE.DEALER);
  });

  it("a register cannot be initialized twice, nor the implementation", async () => {
    const { factory, workshop, stranger } = await loadFixture(fixture);
    await expect(workshop.initialize("A", "A", stranger.address, ROLE.DEALER)).to.be.revertedWith("Initializable: contract is already initialized");
    const impl = await ethers.getContractAt("ServiceRegistry", await factory.implementation());
    await expect(impl.initialize("A", "A", stranger.address, ROLE.DEALER)).to.be.revertedWith("Initializable: contract is already initialized");
  });
});

describe("ServiceRegistry — records", () => {
  it("a staff key records a service; the record is minted to the business and stores only what the chain may know", async () => {
    const { workshop, staff, workshopOwner, relayer } = await loadFixture(fixture);
    const p = await payload();
    const r = await record(workshop.connect(relayer), staff, p);
    await expect(r.tx()).to.emit(workshop, "ServiceRecorded").withArgs(p.recordId, p.vehicleId, staff.address, p.serviceDate, p.kmCommitment, p.contentHash, p.corrects, ethers.hexlify(p.contentRef));
    expect(await workshop.tokenOwnerOf(p.recordId)).to.equal(workshopOwner.address);
    const rec = await workshop.recordOf(p.recordId);
    expect(rec.signer).to.equal(staff.address);
    expect(rec.kmCommitment).to.equal(p.kmCommitment);
  });

  it("refused: a key that is not owner or operator", async () => {
    const { workshop, stranger } = await loadFixture(fixture);
    const outsider = ethers.Wallet.createRandom();
    const r = await record(workshop.connect(stranger), outsider, await payload());
    await expect(r.tx()).to.be.revertedWithCustomError(workshop, "NotAuthorized");
  });

  it("refused: a signature by one key claimed for another (staff's address, stranger's signature)", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const r = await record(workshop.connect(relayer), staff, await payload(), { signWith: ethers.Wallet.createRandom() });
    await expect(r.tx()).to.be.revertedWithCustomError(workshop, "InvalidSignature");
  });

  it("refused: payload changed after signing", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const p = await payload();
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const sig = await sign(staff, workshop, "RecordService", { signer: staff.address, payloadHash: await workshop.hashPayload(p), nonce, deadline });
    const tampered = { ...p, kmCommitment: commit(20000, id("salt")) };
    await expect(workshop.connect(relayer).recordService(tampered, staff.address, nonce, deadline, sig)).to.be.revertedWithCustomError(workshop, "InvalidSignature");
  });

  it("refused: replay of the same signature", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const r = await record(workshop.connect(relayer), staff, await payload());
    await r.tx();
    await expect(r.tx()).to.be.revertedWithCustomError(workshop, "NonceAlreadyUsed");
  });

  it("refused: expired signature, and a deadline beyond the maximum validity (G-07)", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const past = await record(workshop.connect(relayer), staff, await payload(), { deadline: await deadlineIn(-1) });
    await expect(past.tx()).to.be.revertedWithCustomError(workshop, "SignatureExpired");
    const far = await record(workshop.connect(relayer), staff, await payload(), { deadline: await deadlineIn(8 * DAY) });
    await expect(far.tx()).to.be.revertedWithCustomError(workshop, "SignatureValidityTooLong");
  });

  it("a signer cancels an unsent signature (G-07), directly or signed", async () => {
    const { workshop, staff, relayer, privateA } = await loadFixture(fixture);
    const r = await record(workshop.connect(relayer), staff, await payload());
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const sig = await sign(staff, workshop, "CancelNonce", { signer: staff.address, cancelled: r.nonce, nonce, deadline });
    await expect(workshop.connect(relayer).cancelNonceSigned(r.nonce, staff.address, nonce, deadline, sig)).to.emit(workshop, "NonceCancelled");
    await expect(r.tx()).to.be.revertedWithCustomError(workshop, "NonceAlreadyUsed");
    // direct cancellation by an account that pays its gas
    await workshop.connect(privateA).cancelNonce(42);
    expect(await workshop.isNonceUsed(privateA.address, 42)).to.equal(true);
  });

  it("refused: empty vehicleId, commitment, content or reference; date far in the future", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    for (const over of [{ vehicleId: ethers.ZeroHash }, { kmCommitment: ethers.ZeroHash }, { contentHash: ethers.ZeroHash }, { contentRef: "0x" }, { recordId: ethers.ZeroHash }, { serviceDate: 0n }]) {
      const r = await record(workshop.connect(relayer), staff, await payload(over));
      await expect(r.tx()).to.be.revertedWithCustomError(workshop, "InvalidRecord");
    }
    const future = await record(workshop.connect(relayer), staff, await payload({ serviceDate: BigInt(await time.latest()) + BigInt(3 * DAY) }));
    await expect(future.tx()).to.be.revertedWithCustomError(workshop, "ServiceDateInFuture");
  });

  it("corrections must point to an existing record of this register; a record id cannot be reused", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const bad = await record(workshop.connect(relayer), staff, await payload({ corrects: id("nope") }));
    await expect(bad.tx()).to.be.revertedWithCustomError(workshop, "UnknownRecord");
    const first = await payload();
    await (await record(workshop.connect(relayer), staff, first)).tx();
    const fix = await record(workshop.connect(relayer), staff, await payload({ corrects: first.recordId }));
    await expect(fix.tx()).to.emit(workshop, "ServiceRecorded");
    const dup = await record(workshop.connect(relayer), staff, await payload({ recordId: first.recordId }));
    await expect(dup.tx()).to.be.revertedWithCustomError(workshop, "RecordAlreadyExists");
  });

  it("records are not transferable, not even by the owner", async () => {
    const { workshop, staff, relayer, workshopOwner, stranger } = await loadFixture(fixture);
    const p = await payload();
    await (await record(workshop.connect(relayer), staff, p)).tx();
    const owner = workshopOwner.connect(ethers.provider);
    await relayer.sendTransaction({ to: owner.address, value: ethers.parseEther("1") });
    await expect(workshop.connect(owner).transfer(owner.address, stranger.address, p.recordId, true, "0x")).to.be.revertedWithCustomError(workshop, "TransfersDisabled");
  });

  it("record key handed over by an authorized key only, for an existing record", async () => {
    const { workshop, staff, relayer } = await loadFixture(fixture);
    const p = await payload();
    await (await record(workshop.connect(relayer), staff, p)).tx();
    const wrap = ethers.toUtf8Bytes("wrapped-key");
    const share = async (wallet, recordId) => {
      const nonce = nextNonce();
      const deadline = await deadlineIn(3600);
      const sig = await sign(wallet, workshop, "ShareRecordKey", { signer: wallet.address, recordId, wrapHash: ethers.keccak256(wrap), nonce, deadline });
      return workshop.connect(relayer).shareRecordKey(recordId, wrap, wallet.address, nonce, deadline, sig);
    };
    await expect(share(ethers.Wallet.createRandom(), p.recordId)).to.be.revertedWithCustomError(workshop, "NotAuthorized");
    await expect(share(staff, id("unknown"))).to.be.revertedWithCustomError(workshop, "UnknownRecord");
    await expect(share(staff, p.recordId)).to.emit(workshop, "RecordKeyShared");
  });
});

describe("ServiceRegistry — owner operations (GasTrace review A01)", () => {
  it("a Universal Profile owner: an administrator key may add an operator, an access key (SIGN only) may not", async () => {
    const { dealer, adminKey, accessKey, relayer } = await loadFixture(fixture);
    const newStaff = ethers.Wallet.createRandom();
    const op = async (wallet) => {
      const nonce = nextNonce();
      const deadline = await deadlineIn(3600);
      const sig = await sign(wallet, dealer, "SetOperator", { operator: newStaff.address, enabled: true, nonce, deadline });
      return dealer.connect(relayer).setOperatorSigned(newStaff.address, true, nonce, deadline, sig);
    };
    await expect(op(accessKey)).to.be.revertedWithCustomError(dealer, "NotAdministrator");
    await expect(op(ethers.Wallet.createRandom())).to.be.revertedWithCustomError(dealer, "InvalidSignature");
    await expect(op(adminKey)).to.emit(dealer, "OperatorChanged").withArgs(newStaff.address, true);
  });

  it("an access key can still record services for its account (records need SIGN, not administration)", async () => {
    const { dealer, dealerUp, accessKey, relayer } = await loadFixture(fixture);
    const p = await payload();
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const up = await dealerUp.getAddress();
    const sig = await sign(accessKey, dealer, "RecordService", { signer: up, payloadHash: await dealer.hashPayload(p), nonce, deadline });
    await expect(dealer.connect(relayer).recordService(p, up, nonce, deadline, sig)).to.emit(dealer, "ServiceRecorded");
  });

  it("setData only with an administrator signature; LSP4 name stays read-only", async () => {
    const { dealer, adminKey, accessKey, relayer } = await loadFixture(fixture);
    const k = [id("MCBDataKeyWrap")];
    const v = [ethers.toUtf8Bytes("wrap")];
    const go = async (wallet, keys, values) => {
      const nonce = nextNonce();
      const deadline = await deadlineIn(3600);
      const sig = await sign(wallet, dealer, "SetData", { dataKeys: keys, dataValuesHash: ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [values])), nonce, deadline });
      return dealer.connect(relayer).setDataSigned(keys, values, nonce, deadline, sig);
    };
    await expect(go(accessKey, k, v)).to.be.revertedWithCustomError(dealer, "NotAdministrator");
    await go(adminKey, k, v);
    expect(await dealer.getData(k[0])).to.equal(ethers.hexlify(v[0]));
    const LSP4_NAME = "0xdeba1e292f8ba88238e10ab3c7f88bd4be4fac56cad5194b6ecceaf653468af1";
    await expect(go(adminKey, [LSP4_NAME], [ethers.toUtf8Bytes("Other")])).to.be.reverted;
  });

  it("ownership: two steps, administrator signature, renounce disabled; records follow with syncHolders", async () => {
    const { workshop, workshopOwner, staff, relayer, privateA } = await loadFixture(fixture);
    const p = await payload();
    await (await record(workshop.connect(relayer), staff, p)).tx();
    const newOwner = ethers.Wallet.createRandom();
    let nonce = nextNonce();
    let deadline = await deadlineIn(3600);
    let sig = await sign(staff, workshop, "TransferOwnership", { newOwner: newOwner.address, nonce, deadline });
    await expect(workshop.connect(relayer).transferOwnershipSigned(newOwner.address, nonce, deadline, sig)).to.be.revertedWithCustomError(workshop, "InvalidSignature");
    sig = await sign(workshopOwner, workshop, "TransferOwnership", { newOwner: newOwner.address, nonce, deadline });
    await workshop.connect(relayer).transferOwnershipSigned(newOwner.address, nonce, deadline, sig);
    expect(await workshop.owner()).to.equal(workshopOwner.address);
    await expect(workshop.connect(privateA).acceptOwnership()).to.be.revertedWithCustomError(workshop, "NotPendingOwner");
    nonce = nextNonce();
    deadline = await deadlineIn(3600);
    sig = await sign(newOwner, workshop, "AcceptOwnership", { newOwner: newOwner.address, nonce, deadline });
    await workshop.connect(relayer).acceptOwnershipSigned(nonce, deadline, sig);
    expect(await workshop.owner()).to.equal(newOwner.address);
    await workshop.connect(privateA).syncHolders([p.recordId]);
    expect(await workshop.tokenOwnerOf(p.recordId)).to.equal(newOwner.address);
    const owner = newOwner.connect(ethers.provider);
    await relayer.sendTransaction({ to: owner.address, value: ethers.parseEther("1") });
    await expect(workshop.connect(owner).renounceOwnership()).to.be.revertedWithCustomError(workshop, "RenounceDisabled");
  });
});

describe("VehicleRegistry", () => {
  async function issue(dealer, adminKey, dealerUp, relayer, vehicleId = id("VIN-1")) {
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const recordRef = ref("vehicle-verified");
    const up = await dealerUp.getAddress();
    const sig = await sign(adminKey, dealer, "IssueVehicle", { signer: up, vehicleId, contentHash: id("record-v"), recordRefHash: ethers.keccak256(recordRef), nonce, deadline });
    return dealer.connect(relayer).issueVehicle(vehicleId, id("record-v"), recordRef, up, nonce, deadline, sig);
  }

  async function lastVehicleToken(vehicles) {
    const logs = await vehicles.queryFilter(vehicles.filters.VehicleMinted());
    return logs.at(-1).args.tokenId;
  }

  it("open: anyone mints for themselves; two private tokens on the same vehicleId are both active", async () => {
    const { vehicles, privateA, privateB } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    await vehicles.connect(privateB).mint(id("VIN-1"), id("r"), ref("b"));
    const [a, b] = (await vehicles.queryFilter(vehicles.filters.VehicleMinted())).map((l) => l.args.tokenId);
    expect(await vehicles.tokenOwnerOf(a)).to.equal(privateA.address);
    expect(await vehicles.statusOf(a)).to.equal(STATUS.Active);
    expect(await vehicles.statusOf(b)).to.equal(STATUS.Active);
    await expect(vehicles.connect(privateA).mint(ethers.ZeroHash, id("r"), ref("a"))).to.be.revertedWithCustomError(vehicles, "InvalidVehicle");
  });

  it("a dealer's verified token supersedes the private ones, in one step and without loops", async () => {
    const { vehicles, privateA, privateB, dealer, adminKey, dealerUp, relayer } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    await vehicles.connect(privateB).mint(id("VIN-1"), id("r"), ref("b"));
    const [a, b] = (await vehicles.queryFilter(vehicles.filters.VehicleMinted())).map((l) => l.args.tokenId);
    await expect(issue(dealer, adminKey, dealerUp, relayer)).to.emit(dealer, "VehicleIssued");
    const v = await lastVehicleToken(vehicles);
    expect(await vehicles.tokenOwnerOf(v)).to.equal(await dealerUp.getAddress());
    expect(await vehicles.verifiedTokenOf(id("VIN-1"))).to.equal(v);
    expect(await vehicles.statusOf(v)).to.equal(STATUS.Active);
    expect(await vehicles.statusOf(a)).to.equal(STATUS.Superseded);
    expect(await vehicles.statusOf(b)).to.equal(STATUS.Superseded);
  });

  it("refused: a private mint on a vehicleId that already has a verified token", async () => {
    const { vehicles, privateA, dealer, adminKey, dealerUp, relayer } = await loadFixture(fixture);
    await issue(dealer, adminKey, dealerUp, relayer);
    await expect(vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"))).to.be.revertedWithCustomError(vehicles, "VehicleAlreadyVerified");
  });

  it("refused: issuance by anyone but an active dealer or manufacturer register", async () => {
    const { vehicles, factory, workshop, staff, relayer, privateA, dealer, adminKey, dealerUp } = await loadFixture(fixture);
    await expect(vehicles.connect(privateA).issueVerified(id("VIN-9"), id("r"), ref("x"))).to.be.revertedWithCustomError(vehicles, "NotAnActiveIssuer");
    // a workshop register cannot issue vehicles
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const recordRef = ref("x");
    const sig = await sign(staff, workshop, "IssueVehicle", { signer: staff.address, vehicleId: id("VIN-9"), contentHash: id("r"), recordRefHash: ethers.keccak256(recordRef), nonce, deadline });
    await expect(workshop.connect(relayer).issueVehicle(id("VIN-9"), id("r"), recordRef, staff.address, nonce, deadline, sig)).to.be.revertedWithCustomError(vehicles, "RoleCannotIssue");
    // a suspended dealer cannot issue
    await factory.setSuspended(await dealer.getAddress(), true);
    await expect(issue(dealer, adminKey, dealerUp, relayer, id("VIN-9"))).to.be.revertedWithCustomError(vehicles, "NotAnActiveIssuer");
  });

  it("a second verified token is minted in conflict; the arbiter resolves", async () => {
    const { vehicles, factory, dealer, adminKey, dealerUp, relayer, arbiter, stranger, deployer } = await loadFixture(fixture);
    await issue(dealer, adminKey, dealerUp, relayer);
    const first = await lastVehicleToken(vehicles);
    // a manufacturer's register (owner: an EOA) issues the same vehicleId
    const maker = ethers.Wallet.createRandom();
    const salt = id("maker");
    const makerAddr = await factory.predictRegistryAddress(salt);
    await factory.connect(deployer).createRegistry(salt, maker.address, ROLE.MANUFACTURER, "Maker", "MKR");
    const makerReg = await ethers.getContractAt("ServiceRegistry", makerAddr);
    const nonce = nextNonce();
    const deadline = await deadlineIn(3600);
    const recordRef = ref("maker");
    const sig = await sign(maker, makerReg, "IssueVehicle", { signer: maker.address, vehicleId: id("VIN-1"), contentHash: id("m"), recordRefHash: ethers.keccak256(recordRef), nonce, deadline });
    await makerReg.connect(relayer).issueVehicle(id("VIN-1"), id("m"), recordRef, maker.address, nonce, deadline, sig);
    const second = await lastVehicleToken(vehicles);
    expect(await vehicles.statusOf(second)).to.equal(STATUS.Conflict);
    expect(await vehicles.verifiedTokenOf(id("VIN-1"))).to.equal(first);

    await expect(vehicles.connect(stranger).setVerifiedToken(second, id("reason"))).to.be.revertedWithCustomError(vehicles, "NotArbiter");
    await vehicles.connect(arbiter).setVerifiedToken(second, id("reason"));
    await vehicles.connect(arbiter).arbitrate(first, STATUS.Superseded, id("reason"));
    expect(await vehicles.verifiedTokenOf(id("VIN-1"))).to.equal(second);
    expect(await vehicles.statusOf(second)).to.equal(STATUS.Active);
    expect(await vehicles.statusOf(first)).to.equal(STATUS.Superseded);
    await expect(vehicles.connect(arbiter).arbitrate(first, STATUS.Conflict, id("r"))).to.be.revertedWithCustomError(vehicles, "InvalidStatus");
  });

  it("the arbiter can supersede or restore a private token; nobody else can", async () => {
    const { vehicles, privateA, privateB, arbiter } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    const a = await lastVehicleToken(vehicles);
    await expect(vehicles.connect(privateB).arbitrate(a, STATUS.Superseded, id("r"))).to.be.revertedWithCustomError(vehicles, "NotArbiter");
    await expect(vehicles.connect(arbiter).arbitrate(a, STATUS.Superseded, id("r"))).to.emit(vehicles, "StatusArbitrated");
    expect(await vehicles.statusOf(a)).to.equal(STATUS.Superseded);
    await vehicles.connect(arbiter).arbitrate(a, STATUS.None, id("r"));
    expect(await vehicles.statusOf(a)).to.equal(STATUS.Active);
    await expect(vehicles.connect(arbiter).setVerifiedToken(a, id("r"))).to.be.revertedWithCustomError(vehicles, "NotVerifiedToken");
  });

  it("only the holder updates the record and logs entries", async () => {
    const { vehicles, privateA, privateB } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    const a = await lastVehicleToken(vehicles);
    await expect(vehicles.connect(privateB).updateRecord(a, id("r2"), ref("a2"))).to.be.revertedWithCustomError(vehicles, "NotHolder");
    await expect(vehicles.connect(privateB).logEntry(a, commit(1, id("s")), id("c"), ref("e"))).to.be.revertedWithCustomError(vehicles, "NotHolder");
    await expect(vehicles.connect(privateA).logEntry(a, ethers.ZeroHash, id("c"), ref("e"))).to.be.revertedWithCustomError(vehicles, "InvalidVehicle");
    await expect(vehicles.connect(privateA).logEntry(a, commit(1, id("s")), id("c"), ref("e"))).to.emit(vehicles, "EntryLogged");
    await expect(vehicles.connect(privateA).updateRecord(a, id("r2"), ref("a2"))).to.emit(vehicles, "VehicleRecordUpdated");
  });

  it("the contract owner cannot change any vehicle's data (V2 MCB-04), nor renounce", async () => {
    const { vehicles, privateA, deployer } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    const a = await lastVehicleToken(vehicles);
    const KEY = await vehicles.VEHICLE_RECORD_KEY();
    await expect(vehicles.connect(deployer).setDataForTokenId(a, KEY, ref("forged"))).to.be.revertedWithCustomError(vehicles, "OwnerCannotEditVehicles");
    await expect(vehicles.connect(deployer).setDataBatchForTokenIds([a], [KEY], [ref("forged")])).to.be.revertedWithCustomError(vehicles, "OwnerCannotEditVehicles");
    await expect(vehicles.connect(deployer).renounceOwnership()).to.be.revertedWithCustomError(vehicles, "RenounceDisabled");
  });

  it("transfers: no push (direct transfer or operator refused), only offer + accept by the recipient", async () => {
    const { vehicles, privateA, buyer, stranger } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    const a = await lastVehicleToken(vehicles);
    await expect(vehicles.connect(privateA).transfer(privateA.address, buyer.address, a, true, "0x")).to.be.revertedWithCustomError(vehicles, "TransfersOnlyByOffer");
    await vehicles.connect(privateA).authorizeOperator(stranger.address, a, "0x");
    await expect(vehicles.connect(stranger).transfer(privateA.address, stranger.address, a, true, "0x")).to.be.revertedWithCustomError(vehicles, "TransfersOnlyByOffer");
    await expect(vehicles.connect(stranger).offerTransfer(a, stranger.address)).to.be.revertedWithCustomError(vehicles, "NotHolder");
    await vehicles.connect(privateA).offerTransfer(a, buyer.address);
    await expect(vehicles.connect(stranger).acceptTransfer(a)).to.be.revertedWithCustomError(vehicles, "NotOfferedTo");
    await vehicles.connect(buyer).acceptTransfer(a);
    expect(await vehicles.tokenOwnerOf(a)).to.equal(buyer.address);
    expect(await vehicles.pendingTransferOf(a)).to.equal(ethers.ZeroAddress);
    await expect(vehicles.connect(buyer).acceptTransfer(a)).to.be.revertedWithCustomError(vehicles, "NoPendingTransfer");
  });

  it("an offer can be cancelled; a cancelled offer cannot be accepted", async () => {
    const { vehicles, privateA, buyer } = await loadFixture(fixture);
    await vehicles.connect(privateA).mint(id("VIN-1"), id("r"), ref("a"));
    const a = await lastVehicleToken(vehicles);
    await vehicles.connect(privateA).offerTransfer(a, buyer.address);
    await vehicles.connect(privateA).cancelTransferOffer(a);
    await expect(vehicles.connect(buyer).acceptTransfer(a)).to.be.revertedWithCustomError(vehicles, "NoPendingTransfer");
    await expect(vehicles.connect(privateA).offerTransfer(a, privateA.address)).to.be.revertedWithCustomError(vehicles, "InvalidRecipient");
  });

  it("LSP4 token type NFT and number token IDs; registers use unique-id token IDs", async () => {
    const { vehicles, workshop } = await loadFixture(fixture);
    const LSP4_TOKEN_TYPE = "0xe0261fa95db2eb3b5439bd033cda66d56b96f92f243a8228fd87550ed7bdfdb3";
    const LSP8_FORMAT = "0xf675e9361af1c1664c1868cfa3eb97672d6b1a513aa5b81dec34c9ee330e818d";
    expect(await vehicles.getData(LSP4_TOKEN_TYPE)).to.equal(ethers.toBeHex(1, 32));
    expect(await workshop.getData(LSP4_TOKEN_TYPE)).to.equal(ethers.toBeHex(1, 32));
    expect(await vehicles.getData(LSP8_FORMAT)).to.equal(ethers.toBeHex(0, 32));
    expect(await workshop.getData(LSP8_FORMAT)).to.equal(ethers.toBeHex(3, 32)); // UNIQUE_ID
  });
});
