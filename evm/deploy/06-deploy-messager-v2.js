const { ethers } = require("hardhat");

async function main() {
    const [owner] = await ethers.getSigners();
    console.log('owner:', owner.address);
    console.log('balance:', ethers.formatEther(await owner.provider.getBalance(owner.address)));

    const initOwnerAddr = process.env.OWNER_ADDR || owner.address;
    const ccipRouterAddr = process.env.CCIP_ROUTER_ADDR;
    const lzEndPointAddr = process.env.LZ_ENDPOINT_ADDR;
    const mtAddr = process.env.MTOKEN_ADDR;

    console.log('------------------');

    // deploy MTokenMessagerV2
    console.log("deploy MTokenMessagerV2 ...");
    const MTokenMessagerV2 = await ethers.getContractFactory("MTokenMessagerV2");
    //constructor(address _ccipRouter, address _ccipClient, address _lzEndpoint, address _initialOwner)
    const msg2Args = [ccipRouterAddr, mtAddr, lzEndPointAddr, initOwnerAddr];
    const msg = await MTokenMessagerV2.deploy(...msg2Args);
    await msg.waitForDeployment();
    const msgAddr = await msg.getAddress();
    console.log("MTokenMessagerV2 deployed to:", msgAddr);
    await hre.run("verify:verify", {address: msgAddr, constructorArguments: msg2Args})
        .catch(err => console.log(err));
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
