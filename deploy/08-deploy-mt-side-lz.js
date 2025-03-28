const { ethers, upgrades } = require("hardhat");

async function main() {
  const {chainId, chainType, lzEndpointAddr} = hre.network.config;
  const isHardhat = chainId == 31337;
  const isProd = process.env.PROD == "true";
  const [mtName,  mtSymbol]  = isProd ? ["Matrixdock Gold",     "XAUM"]   : ["MAUM",    "MAUM"];
  const [nftName, nftSymbol] = isProd ? ["Matrixdock Gold NFT", "XAUMNFT"]: ["MAUMNFT", "MAUMNFT"];
  console.log("isProd           :", isProd);
  console.log('isHardhat        :', isHardhat);
  console.log('mtName           :', mtName);
  console.log('mtSymbol         :', mtSymbol);
  console.log('nftName          :', nftName);
  console.log('nftSymbol        :', nftSymbol);
  console.log('lzEndpointAddr   :', lzEndpointAddr);

  const [owner] = await ethers.getSigners();
  console.log('ownerAddr        :', owner.address);
  console.log('balance          :', ethers.formatEther(await owner.provider.getBalance(owner.address)));

  const mtOwnerAddr       = process.env.MT_OWNER        || owner.address;
  const mtOperatorAddr    = process.env.MT_OPERATOR     || owner.address;
  const nftOwnerAddr      = process.env.NFT_OWNER       || owner.address;
  const nftPackSignerAddr = process.env.MFT_PACK_SIGNER || owner.address;
  const msgOwnerAddr      = process.env.MSG_OWNER       || owner.address;
  console.log('mtOwnerAddr      :' , mtOwnerAddr);
  console.log('mtOperatorAddr   :' , mtOperatorAddr);
  console.log('nftOwnerAddr     :' , nftOwnerAddr);
  console.log('nftPackSignerAddr:' , nftPackSignerAddr);
  console.log('msgOwnerAddr     :' , msgOwnerAddr);
  console.log('------------------');

  // deploy MTokenSide
  // console.log("deploy MTokenSide ...");
  const MToken = await ethers.getContractFactory("MTokenSide");
  const initArgs = [mtName, mtSymbol, mtOwnerAddr, mtOperatorAddr];
  const mt = await upgrades.deployProxy(MToken, initArgs,
    {kind: "uups"});
  await mt.waitForDeployment();
  const mtAddr = await mt.getAddress();
  console.log("MTokenSide deployed to:", mtAddr);
  if (!isHardhat) {
    await hre.run("verify:verify", {address: mtAddr})
      .catch(err => console.log(err));
  }

  // deploy BullionNFT
  console.log("deploy BullionNFT ...");
  const BullionNFT = await ethers.getContractFactory("BullionEnumerableNFT");
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

  // deploy MTokenMessagerLZ
  console.log("deploy MTokenMessagerLZ ...");
  const MTokenMessagerLZ = await ethers.getContractFactory("MTokenMessagerLZ");
  const msgArgs = [mtAddr, lzEndpointAddr, msgOwnerAddr];
  const msg = await MTokenMessagerLZ.deploy(...msgArgs);
  await msg.waitForDeployment();
  const msgAddr = await msg.getAddress();
  console.log("MTokenMessagerLZ deployed to:", msgAddr);
  if (!isHardhat) {
    await hre.run("verify:verify", {address: msgAddr, constructorArguments: msgArgs})
      .catch(err => console.log(err));
  }

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#erc1967
  console.log('mtProxyAddr      :', mtAddr);
  console.log('mtImplAddr       :', await upgrades.erc1967.getImplementationAddress(mtAddr));
  console.log('nftProxyAddr     :', nftAddr);
  console.log('nftImplAddr      :', await upgrades.erc1967.getImplementationAddress(nftAddr));
  console.log('msgAddr          :', msgAddr);
  console.log('------------------');

  // mt.setNFTContract(nft)
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
