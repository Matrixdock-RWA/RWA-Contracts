const { ethers } = require("hardhat");

// npx hardhat run deploy/00-deploy-feed.js --network sepolia
async function main() {
  const {chainId} = hre.network.config;
  const isHardhat = chainId == 31337;

  // deploy reserve feed
  console.log("deploy FallbackReserveFeed ...");
  const [signer] = await ethers.getSigners();
  const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
  const feed = await FallbackReserveFeed.deploy(signer.address);
  await feed.waitForDeployment();
  const feedAddr = await feed.getAddress();
  console.log("FallbackReserveFeed deployed to:", feedAddr);

  if (!isHardhat) {
    await hre.run("verify:verify", 
      {address: feedAddr, constructorArguments: [signer.address]});
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
