const { ethers, upgrades } = require("hardhat");

async function main() {
    const [owner] = await ethers.getSigners();
    console.log('owner            :', owner.address);
    console.log('balance          :', ethers.formatEther(await owner.provider.getBalance(owner.address)));
    console.log('------------------');

    // deploy BullionNFT
    console.log("deploy Minter ...");
    const poolAccountA = "0xa06804064A5395c8E77041b6EE8Cc38E13E82944";
    const poolAccountB = "0x1a00769059D1DddE4895E035411cdd1f193DAE59";
    const tokensAcceptedByA = [];
    const tokensAcceptedByB = [];

    const BullionMinter = await ethers.getContractFactory("BullionMinter");
    const minter = await upgrades.deployProxy(BullionMinter,
        [owner.address, poolAccountA, poolAccountB, tokensAcceptedByA, tokensAcceptedByB],
        {kind: "uups"});
    await minter.waitForDeployment();
    const minterAddr = await minter.getAddress();
    console.log("BullionMinter deployed to:", minterAddr);
    await hre.run("verify:verify", {address: minterAddr}).catch(err => console.log(err));
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
