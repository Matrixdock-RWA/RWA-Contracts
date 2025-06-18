const { ethers } = require("hardhat");

async function main() {
  const {chainId} = hre.network.config;
  const isHardhat = chainId == 31337;
  const [owner] = await ethers.getSigners();
  console.log('isHardhat:', isHardhat);
  console.log('owner    :', owner.address);
  console.log('balance  :', ethers.formatEther(await owner.provider.getBalance(owner.address)));

  // deploy BullionEnumerableNFT
  const NFT = await ethers.getContractFactory("BullionEnumerableNFT");
  const nft = await NFT.deploy();
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log("BullionEnumerableNFT deployed to:", nftAddr);

  if (!isHardhat) {
    await hre.run("verify:verify", {address: nftAddr});
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
