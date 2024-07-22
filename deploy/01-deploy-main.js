const { ethers, upgrades, erc1967 } = require("hardhat");

const zeroAddr = "0x0000000000000000000000000000000000000000";

// npx hardhat run deploy/01-deploy-main.js --network sepolia
async function main() {
  const [owner] = await ethers.getSigners();
  console.log('owner:', owner.address);
  console.log('balance:', ethers.formatEther(await owner.provider.getBalance(owner.address)));
  
  const {ccipRouterAddr} = hre.network.config;
  console.log('ccipRouterAddr:', ccipRouterAddr);

  // TODO
  const tlMinDelay        = 24 * 3600; // 24h
  const tlProposerAddr    = owner.address;
  const tlExecutorAddr    = owner.address;
  const tlAdminAddr       = zeroAddr;
  const mtSymbol          = "MT";
  const mtOwnerAddr       = owner.address;
  const mtOperatorAddr    = owner.address;
  const nftName           = "BNFT";
  const nftSymbol         = "BNFT";
  const nftOwnerAddr      = owner.address;
  const nftPackSignerAddr = owner.address;

  // deploy fake feed
  console.log("deploy FakeAggregatorV3 ...");
  const initReserve = 100000000n * (10n ** 18n);
  const FakeAggregatorV3 = await ethers.getContractFactory("FakeAggregatorV3");
  const fakeFeed = await FakeAggregatorV3.deploy(initReserve);
  await fakeFeed.waitForDeployment();
  const feedAddr = await fakeFeed.getAddress();
  console.log("FakeAggregatorV3 deployed to:", feedAddr);
  await hre.run("verify:verify", {address: feedAddr, constructorArguments: [initReserve]});

  // deploy TLController
  console.log("deploy TimelockController ...");
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const tlcArgs = [tlMinDelay, [tlProposerAddr], [tlExecutorAddr], tlAdminAddr];
  const tlc = await TimelockController.deploy(...tlcArgs);
  await tlc.waitForDeployment();
  const tlcAddr = await tlc.getAddress();
  console.log("TimelockController deployed to:", tlcAddr);
  await hre.run("verify:verify", {address: tlcAddr, constructorArguments: tlcArgs});

  // deploy MTokenMain
  console.log("deploy MTokenMain ...");
  const MTokenMain = await ethers.getContractFactory("MTokenMain");
  const mtMain = await upgrades.deployProxy(MTokenMain, 
    [mtSymbol, mtOwnerAddr, mtOperatorAddr, feedAddr], 
    {initialOwner: tlcAddr});
  await mtMain.waitForDeployment();
  const mtAddr = await mtMain.getAddress();
  console.log("MTokenMain deployed to:", mtAddr);
  await hre.run("verify:verify", {address: mtAddr});

  // deploy BullionNFT
  console.log("deploy BullionNFT ...");
  const BullionNFT = await ethers.getContractFactory("BullionNFT");
  const nft = await upgrades.deployProxy(BullionNFT, 
    [nftName, nftSymbol, mtAddr, nftPackSignerAddr, nftOwnerAddr],
    {initialOwner: tlcAddr});
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log("BullionNFT deployed to:", nftAddr);
  await hre.run("verify:verify", {address: nftAddr});

  // deploy MTokenMessager
  console.log("deploy MTokenMessager ...");
  const MTokenMessager = await ethers.getContractFactory("MTokenMessager");
  const msg = await MTokenMessager.deploy(ccipRouterAddr, mtAddr);
  await msg.waitForDeployment();
  const msgAddr = await msg.getAddress();
  console.log("MTokenMessager deployed to:", msgAddr);
  await hre.run("verify:verify", {address: msgAddr, constructorArguments: [ccipRouterAddr, mtAddr]});

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#erc1967
  console.log("-----");
  console.log("ownerAddr        :", owner.address);
  console.log("tlProposerAddr   :", tlProposerAddr);
  console.log("tlExecutorAddr   :", tlExecutorAddr);
  console.log("tlAdminAddr      :", tlAdminAddr);
  console.log("mtOwnerAddr      :", mtOwnerAddr);
  console.log("mtOperatorAddr   :", mtOperatorAddr);
  console.log("nftOwnerAddr     :", nftOwnerAddr);
  console.log("nftPackSignerAddr:", nftPackSignerAddr);
  console.log('ccipRouterAddr   :', ccipRouterAddr);
  console.log('reserveFeedAddr  :', feedAddr);
  console.log('tlcAddr          :', tlcAddr);
  console.log('mtAddr           :', mtAddr);
  console.log('nftAddr          :', nftAddr);
  console.log('msgAddr          :', msgAddr);
  console.log('mtAdminAddr      :', await upgrades.erc1967.getAdminAddress(mtAddr));
  console.log('mtImplAddr       :', await upgrades.erc1967.getImplementationAddress(mtAddr));
  console.log('nftAdminAddr     :', await upgrades.erc1967.getAdminAddress(nftAddr));
  console.log('nftImplAddr      :', await upgrades.erc1967.getImplementationAddress(nftAddr));
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });