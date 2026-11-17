require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");

const SOLC_VERSION = "0.8.28";

// Compile with the solc-js build from npm (pinned in package.json) instead of downloading a compiler,
// as GasTrace does: reproducible offline and where binaries.soliditylang.org is unreachable. The long
// version drops solc-js's platform suffix, so explorers recognise the compiler when verifying.
subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async ({ solcVersion }, hre, runSuper) => {
  if (solcVersion !== SOLC_VERSION) return runSuper();
  const longVersion = require("solc").version().replace(/\.Emscripten\.clang$/, "");
  return { compilerPath: require.resolve("solc/soljson.js"), isSolcJs: true, version: SOLC_VERSION, longVersion };
});

// The deployer key lives only on the server that deploys (never in the repository): a new key with no
// permission on ChainIntegrate's Universal Profile, which receives the contracts' ownership afterwards.
const accounts = process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [];

module.exports = {
  solidity: {
    version: SOLC_VERSION,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "shanghai",
    },
  },
  networks: {
    luksoTestnet: {
      url: process.env.LUKSO_TESTNET_RPC_URL || "https://rpc.testnet.lukso.network",
      chainId: 4201,
      accounts,
    },
    luksoMainnet: {
      url: process.env.LUKSO_MAINNET_RPC_URL || "https://rpc.mainnet.lukso.network",
      chainId: 42,
      accounts,
    },
  },
  etherscan: {
    // Blockscout needs no API key, but the plugin wants a non-empty string per network.
    apiKey: { luksoTestnet: "no-api-key-needed", luksoMainnet: "no-api-key-needed" },
    customChains: [
      {
        network: "luksoTestnet",
        chainId: 4201,
        urls: {
          apiURL: "https://explorer.execution.testnet.lukso.network/api",
          browserURL: "https://explorer.execution.testnet.lukso.network",
        },
      },
      {
        network: "luksoMainnet",
        chainId: 42,
        urls: {
          apiURL: "https://explorer.execution.mainnet.lukso.network/api",
          browserURL: "https://explorer.execution.mainnet.lukso.network",
        },
      },
    ],
  },
};
