const { ethers, upgrades, erc1967 } = require("hardhat");

const zeroAddr = "0x0000000000000000000000000000000000000000";

// npx hardhat run deploy/02-deploy-side.js --network bscTestnet
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

  // deploy TLController
  console.log("deploy TimelockController ...");
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const tlcArgs = [tlMinDelay, [tlProposerAddr], [tlExecutorAddr], tlAdminAddr];
  const tlc = await TimelockController.deploy(...tlcArgs);
  await tlc.waitForDeployment();
  const tlcAddr = await tlc.getAddress();
  console.log("TimelockController deployed to:", tlcAddr);
  await hre.run("verify:verify", {address: tlcAddr, constructorArguments: tlcArgs})
    .catch(err => console.log(err));

  // deploy MTokenSide
  console.log("deploy MTokenSide ...");
  const MTokenSide = await ethers.getContractFactory("MTokenSide");
  const mtSide = await upgrades.deployProxy(MTokenSide, 
    [mtSymbol, mtOwnerAddr, mtOperatorAddr], 
    {initialOwner: tlcAddr});
  await mtSide.waitForDeployment();
  const mtAddr = await mtSide.getAddress();
  console.log("MTokenSide deployed to:", mtAddr);
  await hre.run("verify:verify", {address: mtAddr})
    .catch(err => console.log(err));

  // deploy MTokenMessager
  console.log("deploy MTokenMessager ...");
  const MTokenMessager = await ethers.getContractFactory("MTokenMessager");
  const msg = await MTokenMessager.deploy(ccipRouterAddr, mtAddr);
  await msg.waitForDeployment();
  const msgAddr = await msg.getAddress();
  console.log("MTokenMessager deployed to:", msgAddr);
  await hre.run("verify:verify", {address: msgAddr, constructorArguments: [ccipRouterAddr, mtAddr]})
    .catch(err => console.log(err));

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
  console.log('tlcAddr          :', tlcAddr);
  console.log('mtAddr           :', mtAddr);
  console.log('msgAddr          :', msgAddr);
  console.log('mtAdminAddr      :', await upgrades.erc1967.getAdminAddress(mtAddr));
  console.log('mtImplAddr       :', await upgrades.erc1967.getImplementationAddress(mtAddr));
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });