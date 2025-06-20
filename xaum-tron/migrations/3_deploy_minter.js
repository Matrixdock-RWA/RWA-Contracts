const BullionMinter = artifacts.require("./BullionMinter.sol");
const ProxyERC1967 = artifacts.require("./ProxyERC1967.sol");
const { ethers } = require("ethers");

require('dotenv').config();

module.exports = async function(deployer) {
    // for nile testnet, use the following environment variables
    // const owner = process.env.OWNER || "0xD03e95E6656b52655C33576f43787221fCd7D3EA";
    // const poolA = process.env.POOLA || "0xD03e95E6656b52655C33576f43787221fCd7D3EA";
    // const poolB = process.env.POOLB || "0xD03e95E6656b52655C33576f43787221fCd7D3EA";
    // const usdt = process.env.USDT || "0xECa9bC828A3005B9a3b909f2cc5c2a54794DE05F";

    const owner = process.env.OWNER || "0xB596920E993494ECF056136DE9FECA578D27A49A";
    const poolA = process.env.POOLA || "0xB596920E993494ECF056136DE9FECA578D27A49A";
    const poolB = process.env.POOLB || "0xB596920E993494ECF056136DE9FECA578D27A49A";
    const usdt = process.env.USDT || "0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C";

    await deployer.deploy(BullionMinter);
    await BullionMinter.deployed();

    //    function initialize(
    //         address _owner,
    //         address _usdt,
    //         address _poolAccountA,
    //         address _poolAccountB,
    //         address[] memory _tokensAcceptedByA,
    //         address[] memory _tokensAcceptedByB
    //     )
    const iface = new ethers.Interface([
        "function initialize(address,address,address,address,address[],address[])"
    ]);
    const calldata = iface.encodeFunctionData("initialize", [
        owner,
        usdt,
        poolA,
        poolB,
        [],
        [],
    ]);
    await deployer.deploy(ProxyERC1967, BullionMinter.address, calldata);
    await ProxyERC1967.deployed();
};
