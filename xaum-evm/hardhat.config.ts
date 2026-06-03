import 'dotenv/config';
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import "@openzeppelin/hardhat-upgrades";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
};

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
    overrides: {
      "contracts/XAUMDCA.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
      "contracts/MTokenMain.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
    },
  },
  tronSolc: {
    enable: true,
    // Optional: specify an array of contract filenames (without path) to selectively compile. Leave as empty array to compile all contracts.
    filter: [],
    compilers: [{ version: "0.8.24" }], // can be any tron-solc version
    // Optional: Define version remappings for compiler versions
    versionRemapping: [],
  },
  etherscan: {
    apiKey: {
      mainnet   : process.env.ETHSCAN_KEY,
      sepolia   : process.env.ETHSCAN_KEY,
      bsc       : process.env.BSCSCAN_KEY,
      bscTestnet: process.env.BSCSCAN_KEY,
    },
  },
  networks: {
    hardhat: {
      ccipRouterAddr: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
    },
    sepolia: {
      url: "https://ethereum-sepolia-rpc.publicnode.com",
      accounts: [ process.env.KEY ],
      // https://docs.chain.link/ccip/supported-networks/v1_2_0/testnet#ethereum-sepolia
      ccipRouterAddr: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
    },
    bscTestnet: {
      url: "https://bsc-testnet-rpc.publicnode.com",
      accounts: [ process.env.KEY ],
      ccipRouterAddr: "0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f",
    }
  },
};
