// Deploys MyCarBook Service: ServiceRegistryFactory + VehicleRegistry (docs/DESIGN.md §6).
//
// Run on the server, with a NEW local key that has no permission on ChainIntegrate's Universal
// Profile (it only pays the deployment):
//
//   DEPLOYER_KEY=0x… OWNER_UP=0x… [ARBITER=0x…] npx hardhat run --network luksoTestnet scripts/deploy-service.js
//
// Steps: deploy both contracts with the deployer as owner; link them; set the arbiter (if given); write
// LSP4Creators[] / LSP4CreatorsMap on the vehicle registry naming OWNER_UP (what Universal Everything shows
// as creator); hand ownership of both to OWNER_UP. Afterwards the deployer has no power left.
// On mainnet it also needs CONFIRM_MAINNET=yes.
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { ethers } = hre;

const LSP4_CREATORS_ARRAY_KEY = "0x114bd03b3a46d48759680d81ebb2b414fda7d030a7105a851867accf1c2352e7";
const LSP4_CREATORS_MAP_PREFIX = "0x6de85eaf5d982b4e5da0";
const LSP0_INTERFACE_ID = "0x24871b3d";

function creatorsData(creator) {
  const index = ethers.zeroPadValue(ethers.toBeHex(0), 16);
  return {
    keys: [
      LSP4_CREATORS_ARRAY_KEY,
      ethers.concat([ethers.dataSlice(LSP4_CREATORS_ARRAY_KEY, 0, 16), index]),
      ethers.concat([LSP4_CREATORS_MAP_PREFIX, "0x0000", creator]),
    ],
    values: [
      ethers.zeroPadValue(ethers.toBeHex(1), 16), // array length
      creator,
      ethers.concat([LSP0_INTERFACE_ID, index]), // (interface id, index)
    ],
  };
}

async function main() {
  const { chainId } = await ethers.provider.getNetwork();
  const ownerUp = process.env.OWNER_UP;
  if (!ownerUp || !ethers.isAddress(ownerUp)) throw new Error("OWNER_UP (ChainIntegrate's Universal Profile) is required");
  if (chainId === 42n && process.env.CONFIRM_MAINNET !== "yes") throw new Error("mainnet: set CONFIRM_MAINNET=yes");
  const arbiter = process.env.ARBITER || "";
  if (arbiter && !ethers.isAddress(arbiter)) throw new Error("ARBITER is not an address");

  const [deployer] = await ethers.getSigners();
  const owner = ethers.getAddress(ownerUp);
  if ((await ethers.provider.getCode(owner)) === "0x" && chainId !== 31337n) {
    throw new Error("OWNER_UP has no code: it should be a Universal Profile");
  }
  console.log(`network ${hre.network.name} (${chainId}), deployer ${deployer.address}, future owner ${owner}`);

  const factory = await (await ethers.getContractFactory("ServiceRegistryFactory")).deploy(deployer.address);
  await factory.waitForDeployment();
  const vehicles = await (await ethers.getContractFactory("VehicleRegistry")).deploy(
    "MyCarBook Vehicles",
    "MCBV",
    deployer.address,
    await factory.getAddress()
  );
  await vehicles.waitForDeployment();
  console.log(`ServiceRegistryFactory ${await factory.getAddress()} (register implementation ${await factory.implementation()})`);
  console.log(`VehicleRegistry        ${await vehicles.getAddress()}`);

  await (await factory.setVehicleRegistry(await vehicles.getAddress())).wait();
  if (arbiter) await (await vehicles.setArbiter(ethers.getAddress(arbiter))).wait();

  const creators = creatorsData(owner);
  await (await vehicles.setDataBatch(creators.keys, creators.values)).wait();

  await (await vehicles.transferOwnership(owner)).wait();
  await (await factory.transferOwnership(owner)).wait();

  // Checks: the deployer has nothing left.
  if ((await vehicles.owner()) !== owner || (await factory.owner()) !== owner) throw new Error("ownership not transferred");
  if ((await factory.vehicleRegistry()) !== (await vehicles.getAddress())) throw new Error("registries not linked");

  const out = {
    network: hre.network.name,
    chainId: Number(chainId),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    owner,
    arbiter: arbiter || null,
    serviceRegistryFactory: await factory.getAddress(),
    serviceRegistryImplementation: await factory.implementation(),
    vehicleRegistry: await vehicles.getAddress(),
  };
  const dir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${hre.network.name}.json`);
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
  console.log(`written ${path.relative(process.cwd(), file)}`);
  console.log(
    "\nNext, from ChainIntegrate's Universal Profile: add the vehicle registry to LSP12IssuedAssets[] (so" +
      " Universal Everything shows the creator as verified) and, if not given here, set the arbiter."
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
