const MTokenSide = artifacts.require("./MTokenSide.sol");
const ProxyERC1967 = artifacts.require("./ProxyERC1967.sol");
const MTokenMessagerLZ = artifacts.require("./MTokenMessagerLZ.sol");
const { ethers } = require("ethers");

require('dotenv').config();

module.exports = async function(deployer) {
    const isProd = process.env.PROD === "true" || false;
    const owner = process.env.OWNER || "0xB596920E993494ECF056136DE9FECA578D27A49A";
    const operator = process.env.OPERATOR || "0xB596920E993494ECF056136DE9FECA578D27A49A"
    const endpoint = process.env.LZ_ENDPOINT || "0x0Af59750D5dB5460E5d89E268C474d5F7407c061";
    const [mtName,  mtSymbol]  = isProd ? ["Matrixdock Gold","XAUM"] : ["MAUM","MAUM"];

    await deployer.deploy(MTokenSide);
    await MTokenSide.deployed();

    const abi = ["function initialize(string memory name, string memory symbol, address _owner, address _operator)"];
    const iface = new ethers.Interface(abi);
    const calldata = iface.encodeFunctionData("initialize", [
        mtName,
        mtSymbol,
        owner,
        operator,
    ]);

    await deployer.deploy(ProxyERC1967, MTokenSide.address, calldata);
    await ProxyERC1967.deployed();

    await deployer.deploy(MTokenMessagerLZ, ProxyERC1967.address, endpoint, owner);
    await MTokenMessagerLZ.deployed();
};
