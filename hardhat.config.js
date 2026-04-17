require("@nomiclabs/hardhat-waffle");
require("hardhat-prettier");
require("hardhat-contract-sizer");
require("hardhat-gas-reporter");
require('dotenv').config();

const { task } = require("hardhat/config");

// Define the task
task("increment-days", "Increments the days")
  .addOptionalParam("days", "The number of days to increment", 1, types.int)
  .setAction(async (taskArgs, hre) => {
    const { days } = taskArgs;
    await hre.network.provider.send("evm_increaseTime", [days * 86400]);
    await hre.network.provider.send("evm_mine");
    console.log(`------------------ incremented ${days} day(s) ------------------`);
  });

const commonSettings = {
  optimizer: {
    enabled: true,
    runs: 200,
  },
};


const compilers = [
  {
    version: "0.8.4",
    settings: {
      ...commonSettings,
    },
  },
  {
    version: "0.8.23",
    settings: {
      ...commonSettings,
      viaIR: false,
    },
  },
  {
    version: "0.5.13",
    settings: {
      ...commonSettings,
    },
  },
];


module.exports = {
  gasReporter: {
    enabled: true,
    currency: 'USD',
    gasPrice: 100,
  },
  solidity: {
    compilers: [
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.8.26",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.5.13",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      }
    ]
  },
  networks: {
    hardhat: {
      blockGasLimit: 352450000,
      allowUnlimitedContractSize: true,
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.SEPOLIA_DEPLOYER_PRIVATE_KEY // Gotta get your own keys Brah!!
        ? [process.env.SEPOLIA_DEPLOYER_PRIVATE_KEY]
        : [],
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || "",
  },
  contractSizer: {
    only: ['^contracts\\/v2\\/.+\\.sol:[^\\/]+$']
  }
};
