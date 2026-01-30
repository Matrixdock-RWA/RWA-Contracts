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
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  etherscan: {
    apiKey: {
      mainnet   : process.env.ETHSCAN_KEY,
      sepolia   : process.env.ETHSCAN_KEY,
    },
  },
  networks: {
    hardhat: {
      ccipRouterAddr: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
    }
  },
};
