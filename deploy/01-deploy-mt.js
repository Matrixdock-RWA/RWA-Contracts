const { ethers, upgrades } = require("hardhat");

const zeroAddr = "0x0000000000000000000000000000000000000000";

// npx hardhat run deploy/01-deploy-mt.js --network sepolia
// npx hardhat run deploy/01-deploy-mt.js --network bscTestnet
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

  // TODO
  const mtSymbol          = "MT";
  const mtOwnerAddr       = owner.address;
  const mtOperatorAddr    = owner.address;
  const nftName           = "BNFT";
  const nftSymbol         = "BNFT";
  const nftOwnerAddr      = owner.address;
  const nftPackSignerAddr = owner.address;

  // deploy MTokenMain/Side
  const mtContract = isMainChain ? "MTokenMain" : "MTokenSide";
  const MToken = await ethers.getContractFactory(mtContract);
  const initArgs = isMainChain
    ? [mtSymbol, mtOwnerAddr, mtOperatorAddr, reserveFeedAddr]
    : [mtSymbol, mtOwnerAddr, mtOperatorAddr];
  const mt = await upgrades.deployProxy(MToken, initArgs,
    {kind: "uups"});
  await mt.waitForDeployment();
  const mtAddr = await mt.getAddress();
  console.log(mtContract, "deployed to:", mtAddr);
  if (!isHardhat) {
    await hre.run("verify:verify", {address: mtAddr})
      .catch(err => console.log(err));
  }

  // deploy BullionNFT
  console.log("deploy BullionNFT ...");
  const BullionNFT = await ethers.getContractFactory("BullionNFT");
  const nft = await upgrades.deployProxy(BullionNFT, 
    [nftName, nftSymbol, mtAddr, nftPackSignerAddr, nftOwnerAddr],
    {kind: "uups"});
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log("BullionNFT deployed to:", nftAddr);
  if (!isHardhat) {
    await hre.run("verify:verify", {address: nftAddr})
      .catch(err => console.log(err));
  }

  // deploy MTokenMessager
  console.log("deploy MTokenMessager ...");
  const MTokenMessager = await ethers.getContractFactory("MTokenMessager");
  const msg = await MTokenMessager.deploy(ccipRouterAddr, mtAddr);
  await msg.waitForDeployment();
  const msgAddr = await msg.getAddress();
  console.log("MTokenMessager deployed to:", msgAddr);
  if (!isHardhat) {
    await hre.run("verify:verify", {address: msgAddr, constructorArguments: [ccipRouterAddr, mtAddr]})
      .catch(err => console.log(err));
  }

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#erc1967
  console.log("-----");
  console.log("ownerAddr        :", owner.address);
  console.log("mtOwnerAddr      :", mtOwnerAddr);
  console.log("mtOperatorAddr   :", mtOperatorAddr);
  console.log("nftOwnerAddr     :", nftOwnerAddr);
  console.log("nftPackSignerAddr:", nftPackSignerAddr);
  console.log('ccipRouterAddr   :', ccipRouterAddr);
  console.log('reserveFeedAddr  :', reserveFeedAddr);
  console.log('mtProxyAddr      :', mtAddr);
  console.log('mtImplAddr       :', await upgrades.erc1967.getImplementationAddress(mtAddr));
  console.log('nftProxyAddr     :', nftAddr);
  console.log('nftImplAddr      :', await upgrades.erc1967.getImplementationAddress(nftAddr));
  console.log('msgAddr          :', msgAddr);

  // mt.setNFTContract(nft)
  console.log("-----");
  console.log("call setNFTContract() ...");
  const tx = await mt.setNFTContract(nftAddr);
  console.log('tx:', tx.hash);
  await tx.wait();

  // mt.setMessager(msg)
  console.log("call setMessager() ...");
  const tx1 = await mt.setMessager(msgAddr);
  console.log('tx1:', tx1.hash);
  await tx1.wait();
  const tx2 = await mt.setMessager(msgAddr);
  console.log('tx2:', tx2.hash);
  await tx2.wait();
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
