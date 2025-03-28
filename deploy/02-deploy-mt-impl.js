const { ethers } = require("hardhat");

async function main() {
  const [owner] = await ethers.getSigners();
  console.log('owner            :', owner.address);
  console.log('balance          :', ethers.formatEther(await owner.provider.getBalance(owner.address)));

  const {chainId, chainType, ccipRouterAddr, reserveFeedAddr} = hre.network.config;
  const isHardhat = chainId == 31337;
  const isMainChain = !!reserveFeedAddr;
  console.log('ccipRouterAddr   :', ccipRouterAddr);
  console.log('reserveFeedAddr  :', reserveFeedAddr);
  console.log('isHardhat        :', isHardhat);
  console.log("isMainChain      :", isMainChain);

  // deploy MTokenMain/Side
  const mtContract = isMainChain ? "MTokenMain" : "MTokenSide";
  const MToken = await ethers.getContractFactory(mtContract);
  const mt = await MToken.deploy();
  await mt.waitForDeployment();
  const mtAddr = await mt.getAddress();
  console.log(mtContract, "deployed to:", mtAddr);

  if (!isHardhat) {
    await hre.run("verify:verify", {address: mtAddr});
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
