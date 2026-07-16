import 'dotenv/config';
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import "@openzeppelin/hardhat-upgrades";
import 'hardhat-storage-layout';

const KEY = process.env.KEY || "0x0000000000000000000000000000000000000000000000000000000000000123";

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
  networks: {
    hardhat: {},
    ethMainnet: {
      url: "https://ethereum-rpc.publicnode.com",
      accounts: [ KEY ],
    },
    bscMainnet: {
      url: "https://bsc-rpc.publicnode.com",
      accounts: [ KEY ],
    },
  },
};
