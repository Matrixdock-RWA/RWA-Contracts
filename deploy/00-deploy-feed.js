const { ethers } = require("hardhat");

// npx hardhat run deploy/00-deploy-feed.js --network sepolia
async function main() {
  const {chainId} = hre.network.config;
  const isHardhat = chainId == 31337;

  // deploy fake feed
  console.log("deploy FakeAggregatorV3 ...");
  const initReserve = 100000000n * (10n ** 18n);
  const FakeAggregatorV3 = await ethers.getContractFactory("FakeAggregatorV3");
  const fakeFeed = await FakeAggregatorV3.deploy(initReserve);
  await fakeFeed.waitForDeployment();
  const feedAddr = await fakeFeed.getAddress();
  console.log("FakeAggregatorV3 deployed to:", feedAddr);

  if (!isHardhat) {
    await hre.run("verify:verify", 
      {address: feedAddr, constructorArguments: [initReserve]});
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
