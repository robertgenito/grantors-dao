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
//      allowUnlimitedContractSize: true,
      blockGasLimit: 352450000,
      allowUnlimitedContractSize: true,
//      loggingEnabled: true, // Enable detailed logging
//    },
//    sepolia: {
//      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
//      accounts: [
//        process.env.GENIUS_CONTRACT_AUCTIONS,
//        process.env.GENIUS_CONTRACT_CALENDAR,
//        process.env.GENIUS_CONTRACT_COLLATERAL_AUCTIONS,
//        process.env.GENIUS_CONTRACT_GIFT_TOKEN,
//        process.env.GENIUS_CONTRACT_VAULT,
//        process.env.GENIUS_CONTRACT_MINERS,
//        process.env.GENIUS_CONTRACT_NFT_CONTROLLER,
//        process.env.GENIUS_CONTRACT_NFT_EDITION,
//        process.env.GENIUS_CONTRACT_NFT_ROYALTIES,
//        process.env.GENIUS_CONTRACT_PREMIUM,
//        process.env.GENIUS_CONTRACT_REWARDS,
//        process.env.GENIUS_CONTRACT_TOKEN
//      ],
//      gasPrice: 20000000000,
//      gas: 7000000
    }
  },
  contractSizer: {
    only: ['^contracts\\/v2\\/.+\\.sol:[^\\/]+$']
  }
};

