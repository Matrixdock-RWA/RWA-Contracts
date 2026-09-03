const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {
  deployTestFixture, getTS, setupDelay, zeroAddr,
} = require("./MTokenTestUtils.js");

async function sign712Pack(signer, nftAddr, ownerAddr, amt, bullionId, deadline) {
  const domain = {
    name: 'BNFT',
    version: '1',
    chainId: 31337, // hardhat
    verifyingContract: nftAddr,
  };

  const types = {
    Pack: [
      { name: 'owner', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'bullion', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
  };

  const pack = {
    owner: ownerAddr,
    amount: amt,
    bullion: bullionId,
    deadline: deadline,
  };

  const signature = await signer.signTypedData(domain, types, pack);
  // console.log(signature);

  const r = signature.slice(0, 66);
  const s = '0x' + signature.slice(66, 130);
  const v = '0x' + signature.slice(130, 132);
  // console.log(r, s, v);
  return [r, s, v];
}

function verify712Pack(nftAddr, ownerAddr, amt, bullionId, deadline, sig, extraArgs) {
  const domain = {
    name: extraArgs?.domainName || 'BNFT',
    version: '1',
    chainId: extraArgs?.chainId || 31337,
    verifyingContract: nftAddr,
  };

  const types = {
    Pack: [
      { name: 'owner', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'bullion', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
  };

  const pack = {
    owner: ownerAddr,
    amount: amt,
    bullion: bullionId,
    deadline: deadline,
  };

  const addr = ethers.verifyTypedData(domain, types, pack, sig);
  return addr;
}

describe("BullionNFT", function () {

  const OP_SET_PACK_SIGNER = ethers.keccak256(ethers.toUtf8Bytes("OP_SET_PACK_SIGNER"));

  describe("delayedOps", function () {

    it("setPackSigner", async function () {
      const { mt, nft, operator, packSigner, alice } = await loadFixture(deployTestFixture);
      const _c = nft.connect(operator);

      const delay = 10000;
      await setupDelay(mt, delay, 24 * 3600);

      const initVal = packSigner.address;
      const newVal = "0x0000000000000000000000000000000000000011";
      const getEt = async () => (await nft.requestMap(OP_SET_PACK_SIGNER)).effectiveTime;

      // initial state: no pending request
      expect(await nft.packSigner()).to.equal(initVal);
      expect(await getEt()).to.equal(0n);

      // first call: queues, emits the generic DelayedOpRequest
      const tx1 = await _c.setPackSigner(newVal);
      const ts1 = await getTS(tx1);
      await expect(tx1).to.emit(nft, "DelayedOpRequest")
        .withArgs(OP_SET_PACK_SIGNER, BigInt(initVal), BigInt(newVal), anyValue);
      expect(await nft.packSigner()).to.equal(initVal);
      expect(await getEt()).to.equal(ts1 + delay);

      // second call while pending: TooEarlyToExecute
      await expect(_c.setPackSigner(newVal))
        .to.be.revertedWithCustomError(nft, "TooEarlyToExecute")
        .withArgs(OP_SET_PACK_SIGNER);

      // execute after delay — entry deleted after execution
      await time.increase(delay + 1);
      await expect(_c.setPackSigner(newVal)).to.emit(nft, "DelayedOpEffected")
        .withArgs(OP_SET_PACK_SIGNER, BigInt(newVal));
      expect(await nft.packSigner()).to.equal(newVal);
      expect(await getEt()).to.equal(0n);

      // make alice the revoker on MToken (NFT reads revoker from MToken;
      // revoker rotation is gated by govDelay)
      await mt.setRevoker(alice.address);
      await time.increase(24 * 3600 + 1);
      await mt.connect(alice).acceptRevoker();

      // re-queue so there is something to revoke
      await _c.setPackSigner(newVal);
      await nft.connect(alice).revokeNextPackSigner();
      expect(await getEt()).to.equal(0n);

      // non-revoker can't revoke
      await expect(nft.connect(packSigner).revokeNextPackSigner())
        .to.be.revertedWithCustomError(nft, "NotRevoker")
        .withArgs(packSigner.address);

      // non-operator can't set
      await expect(nft.connect(alice).setPackSigner(newVal))
        .to.be.revertedWithCustomError(nft, "NotOperator")
        .withArgs(alice.address);
    });

  });

  it("init", async function () {
    const {mt, nft, owner, packSigner} = await loadFixture(deployTestFixture);
    expect(await nft.owner()).to.equal(owner.address);
    expect(await nft.name()).to.equal("BullionNFT");
    expect(await nft.symbol()).to.equal("BNFT");
    expect(await nft.mtokenContract()).to.equal(mt.target);
    expect(await nft.packSigner()).to.equal(packSigner.address);
  });

  it("setBaseURI", async function () {
    const { mt, nft, operator } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    
    await nft.connect(operator).setBaseURI("hello");
    expect(await nft.tokenURI(101)).to.equal("hello101");
  });

  it("onlyOperator", async function () {
    const {nft, alice} = await loadFixture(deployTestFixture);

    const testCases = [
      nft.connect(alice).setBaseURI("hello"),
      nft.connect(alice).setPackSigner(alice.address),
      nft.connect(alice).addToLockedList(123, "0x1234"),
      nft.connect(alice).removeFromLockedList(123),
      nft.connect(alice).mintAndPack(234, 567, 0),
      nft.connect(alice).unpackAndRedeem(234, alice.address, "0x5678"),
      nft.connect(alice).pack(10000, 888),
      // nft.connect(alice).unpack(888),
      nft.connect(alice).batchUnpackAndRedeem([1, 2, 3], alice.address, "0xABCD"),
      nft.connect(alice).batchPack([100, 200, 300], [1, 2, 3]),
      nft.connect(alice).batchUnpack([1, 2, 3]),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "NotOperator")
        .withArgs(alice.address);
    }
  });

  it("onlyNotBlocked", async function () {
    const {mt, nft, operator, alice, bob} = await loadFixture(deployTestFixture);
    await mt.connect(operator).addToBlockedList(alice.address);

    const testCases = [
      nft.connect(alice).transferFrom(operator.address, bob.address, 123),
      nft.connect(alice).safeTransferFrom(operator.address, bob.address, 123),
      nft.connect(alice).multiTransferFrom(operator.address, [bob.address], [123]),
      nft.connect(alice).multiSafeTransferFrom(operator.address, [bob.address], [123]),
      nft.connect(alice).multiSafeTransferFrom2(operator.address, [bob.address], [123], "0x"),
      nft.transferFrom(alice.address, bob.address, 123),
      nft.safeTransferFrom(alice.address, bob.address, 123),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "BlockedAccount")
        .withArgs(alice.address);
    }
  });

  it("error: TokenLocked", async function () {
    const {nft, operator, alice, bob} = await loadFixture(deployTestFixture);
    await nft.connect(operator).addToLockedList(1234, "0x1234");

    const testCases = [
      nft.transferFrom(bob.address, alice.address, 1234),
      nft.safeTransferFrom(bob.address, alice.address, 1234),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "TokenLocked")
        .withArgs(1234);
    }
  });

  it("error: TokenLocked blocks unpack (cannot bypass lock via unpack)", async function () {
    const {mt, nft, operator, bob} = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await mt.connect(operator).mintTo(operator.address, 10000, 0);
    await mt.connect(operator).mintTo(operator.address, 10000, 0);
    await nft.connect(operator).pack(10000, 101);
    await nft.connect(operator).transferFrom(operator.address, bob.address, 101);

    await nft.connect(operator).addToLockedList(101, "0x1234");

    await expect(nft.connect(bob).unpack(101))
      .to.be.revertedWithCustomError(nft, "TokenLocked")
      .withArgs(101);

    await nft.connect(operator).removeFromLockedList(101);
    await expect(nft.connect(bob).unpack(101))
      .to.emit(mt, "Transfer").withArgs(nft.target, bob.address, 10000);
  });

  it("error: TokenLocked blocks unpackAndRedeem (cannot bypass lock via unpackAndRedeem)", async function () {
    const {mt, nft, operator, alice} = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await mt.connect(operator).mintTo(operator.address, 10000, 0);
    await mt.connect(operator).mintTo(operator.address, 10000, 0);
    await nft.connect(operator).pack(10000, 101);

    // NFT frozen while it already sits in operator's wallet
    await nft.connect(operator).addToLockedList(101, "0x1234");

    await expect(nft.connect(operator).unpackAndRedeem(101, alice.address, "0x1234"))
      .to.be.revertedWithCustomError(nft, "TokenLocked")
      .withArgs(101);

    await nft.connect(operator).removeFromLockedList(101);
    await expect(nft.connect(operator).unpackAndRedeem(101, alice.address, "0x1234"))
      .to.emit(mt, "Redeem").withArgs(alice.address, 10000, "0x1234");
  });

  it("error: TransferToContract", async function () {
    const {nft, bob} = await loadFixture(deployTestFixture);

    const testCases = [
      nft.transferFrom(bob.address, nft.target, 1234),
      nft.safeTransferFrom(bob.address, nft.target, 1234),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "TransferToContract");
    }
  });

  it("error: ArgsMismatch", async function () {
    const {nft, operator, alice, bob} = await loadFixture(deployTestFixture);

    const testCases = [
      nft.multiTransferFrom(bob.address, [alice.address], [1234, 5678]),
      nft.multiSafeTransferFrom(bob.address, [alice.address], [1234, 5678]),
      nft.multiSafeTransferFrom2(bob.address, [alice.address], [1234, 5678], "0x"),
      nft.connect(operator).batchPack([100, 200, 300], [1, 2, 3, 4]),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "ArgsMismatch");
    }
  });

  it("error: NotNftOwner", async function () {
    const {mt, nft, operator, alice, bob} = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 0);
    await nft.connect(operator).mintAndPack(10000, 101, 0);
    await nft.connect(operator).transferFrom(operator.address, bob.address, 101);

    const testCases = [
      nft.connect(operator).unpackAndRedeem(101, alice.address, "0x1234"),
      nft.connect(operator).unpack(101),
    ];

    for (const testCase of testCases) {
      await expect(testCase).to.be.revertedWithCustomError(nft, "NotNftOwner")
        .withArgs(101, operator.address);
    }
  });

  it("lockedList", async function () {
    const { nft, operator } = await loadFixture(deployTestFixture);

    expect(await nft.isLocked(1)).to.equal(false);
    expect(await nft.isLocked(2)).to.equal(false);
    expect(await nft.isLocked(3)).to.equal(false);
    expect(await nft.isLocked(4)).to.equal(false);

    await expect(nft.connect(operator).addToLockedList(1, "0xa1"))
      .to.emit(nft, "LockPlaced").withArgs(1, "0xa1");
    await expect(nft.connect(operator).addToLockedList(3, "0xa3"))
      .to.emit(nft, "LockPlaced").withArgs(3, "0xa3");
    await expect(nft.connect(operator).addToLockedList(4, "0xa4"))
      .to.emit(nft, "LockPlaced").withArgs(4, "0xa4");
    expect(await nft.isLocked(1)).to.equal(true);
    expect(await nft.isLocked(2)).to.equal(false);
    expect(await nft.isLocked(3)).to.equal(true);
    expect(await nft.isLocked(4)).to.equal(true);

    await expect(nft.connect(operator).removeFromLockedList(4))
      .to.emit(nft, "LockReleased").withArgs(4);
    expect(await nft.isLocked(1)).to.equal(true);
    expect(await nft.isLocked(2)).to.equal(false);
    expect(await nft.isLocked(3)).to.equal(true);
    expect(await nft.isLocked(4)).to.equal(false);
  });

  it("transferFrom", async function () {
    const { mt, nft, operator, alice, bob } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    expect(await nft.balanceOf(operator.address)).to.equal(1);

    await mt.connect(operator).addToBlockedList(alice.address);
    await expect(nft.connect(alice).transferFrom(operator.address, bob.address, 101))
      .to.be.revertedWithCustomError(nft, "BlockedAccount")
      .withArgs(alice.address);
    await expect(nft.connect(operator).transferFrom(alice.address, bob.address, 101))
      .to.be.revertedWithCustomError(nft, "BlockedAccount")
      .withArgs(alice.address);

    await mt.connect(operator).removeFromBlockedList(alice.address);
    await nft.connect(operator).addToLockedList(101, "0x0101");
    await expect(nft.connect(operator).transferFrom(operator.address, bob.address, 101))
      .to.be.revertedWithCustomError(nft, "TokenLocked")
      .withArgs(101);

    await nft.connect(operator).removeFromLockedList(101);
    await expect(nft.connect(operator).transferFrom(operator.address, bob.address, 101))
      .to.emit(nft, "Transfer")
      .withArgs(operator.address, bob.address, 101);
  });

  it("multiTransferFrom", async function () {
    const { mt, nft, operator, alice, bob } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(20000, 102, 2);
    await nft.connect(operator).mintAndPack(20000, 102, 2);
    expect(await nft.balanceOf(operator.address)).to.equal(2);

    await expect(nft.connect(operator)
      .multiTransferFrom(operator.address, [alice.address, bob.address], [102, 101]))
      .to.emit(nft, "Transfer").withArgs(operator.address, alice.address, 102)
      .to.emit(nft, "Transfer").withArgs(operator.address, bob.address, 101)
      ;
  });

  it("safeTransferFrom", async function () {
    const { mt, nft, operator, alice, bob } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    expect(await nft.balanceOf(operator.address)).to.equal(1);

    await mt.connect(operator).addToBlockedList(alice.address);
    await expect(nft.connect(alice).safeTransferFrom2(operator.address, bob.address, 101, "0x"))
      .to.be.revertedWithCustomError(nft, "BlockedAccount")
      .withArgs(alice.address);
    await expect(nft.connect(operator).safeTransferFrom2(alice.address, bob.address, 101, "0x"))
      .to.be.revertedWithCustomError(nft, "BlockedAccount")
      .withArgs(alice.address);

    await mt.connect(operator).removeFromBlockedList(alice.address);
    await nft.connect(operator).addToLockedList(101, "0x0101");
    await expect(nft.connect(operator).safeTransferFrom2(operator.address, bob.address, 101, "0x"))
      .to.be.revertedWithCustomError(nft, "TokenLocked")
      .withArgs(101);

    await nft.connect(operator).removeFromLockedList(101);
    await expect(nft.connect(operator).safeTransferFrom2(operator.address, bob.address, 101, "0x"))
      .to.emit(nft, "Transfer")
      .withArgs(operator.address, bob.address, 101);
  });

  it("multiSafeTransferFrom", async function () {
    const { mt, nft, operator, alice, bob } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(10000, 101, 1);
    await nft.connect(operator).mintAndPack(20000, 102, 2);
    await nft.connect(operator).mintAndPack(20000, 102, 2);
    await nft.connect(operator).mintAndPack(30000, 103, 3);
    await nft.connect(operator).mintAndPack(30000, 103, 3);
    await nft.connect(operator).mintAndPack(40000, 104, 4);
    await nft.connect(operator).mintAndPack(40000, 104, 4);
    expect(await nft.balanceOf(operator.address)).to.equal(4);

    await expect(nft.connect(operator)
      .multiSafeTransferFrom(operator.address, [alice.address, bob.address], [102, 101]))
      .to.emit(nft, "Transfer").withArgs(operator.address, alice.address, 102)
      .to.emit(nft, "Transfer").withArgs(operator.address, bob.address, 101)
      ;

    await expect(nft.connect(operator)
      .multiSafeTransferFrom2(operator.address, [alice.address, bob.address], [103, 104], "0x"))
      .to.emit(nft, "Transfer").withArgs(operator.address, alice.address, 103)
      .to.emit(nft, "Transfer").withArgs(operator.address, bob.address, 104)
      ;
  });

  it("pack/unpack", async function () {
    const { mt, nft, operator, alice, bob } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await mt.connect(operator).mintTo(operator.address, 100000, 0);
    await mt.connect(operator).mintTo(operator.address, 100000, 0);

    // pack 101, 102, 103
    await expect(nft.connect(operator).pack(10000, 101))
      .to.emit(mt, "Transfer").withArgs(operator.address, nft.target, 10000)
      .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 101);
    await expect(nft.connect(operator).pack(20000, 102))
      .to.changeTokenBalances(mt, [operator.address, nft.target], [-20000, 20000])
    await expect(nft.connect(operator).pack(10000, 101))
      .to.be.revertedWithCustomError(nft, "DuplicatedBullion")
      .withArgs(101);
    await nft.connect(operator).pack(30000, 103);

    // transfer to alice, bob
    await nft.connect(operator).transferFrom(operator.address, alice.address, 101);
    await nft.connect(operator).transferFrom(operator.address, bob.address, 102);

    // unpack 101, 102
    await expect(nft.connect(alice).unpack(101))
      .to.emit(mt, "Transfer").withArgs(nft.target, alice.address, 10000)
      .to.emit(nft, "Transfer").withArgs(alice, zeroAddr, 101);
    await expect(nft.connect(bob).unpack(102))
      .to.changeTokenBalances(mt, [nft.target, bob.address], [-20000, 20000]);

    await expect(nft.connect(operator).unpack(404))
      .to.be.revertedWithCustomError(nft, "NoSuchBullion")
      .withArgs(404);

    // pack 101, 102
    await nft.connect(operator).pack(11000, 101);
    await nft.connect(operator).pack(22000, 102);
  });

  // fix repro: amount 0 used to leave packedCoins[bullion] at 0 after minting,
  // which _getAmount/_ensureBullionNotExist treat as "no such bullion" — the NFT
  // minted but could never be unpacked/redeemed again. pack/packWithSig/mintAndPack
  // now reject amount == 0 upfront instead of minting a permanently stuck NFT.
  it("error: pack(0, bullion) reverts instead of minting a zombie NFT", async function () {
    const { mt, nft, operator } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);

    await expect(nft.connect(operator).pack(0, 101))
      .to.be.revertedWithCustomError(nft, "ZeroValue");
  });

  it("error: mintAndPack(0, bullion, nonce) reverts instead of minting a zombie NFT", async function () {
    const { mt, nft, operator } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);

    await expect(nft.connect(operator).mintAndPack(0, 202, 1))
      .to.be.revertedWithCustomError(nft, "ZeroValue");
  });

  it("error: packWithSig with amount 0 reverts instead of minting a zombie NFT", async function () {
    const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await nft.connect(operator).setPackSigner(alice.address);
    await nft.connect(operator).setPackSigner(alice.address);

    const [r, s, v] = await sign712Pack(alice, nft.target, alice.address, 0, 303, 9999999999);
    await expect(nft.connect(alice).packWithSig(0, 303, 9999999999, v, r, s))
      .to.be.revertedWithCustomError(nft, "ZeroValue");
  });

  it("pack/unpack: batch", async function () {
    const { mt, nft, operator } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await mt.connect(operator).mintTo(operator.address, 65000, 0);
    await mt.connect(operator).mintTo(operator.address, 65000, 0);

    await expect(nft.connect(operator).batchPack([10000, 20000], [100, 200]))
      .to.emit(mt, "Transfer").withArgs(operator.address, nft.target, 10000)
      .to.emit(mt, "Transfer").withArgs(operator.address, nft.target, 20000)
      .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 100)
      .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 200);

    await expect(nft.connect(operator).batchUnpack([100, 200]))
      .to.emit(mt, "Transfer").withArgs(nft.target, operator.address, 10000)
      .to.emit(mt, "Transfer").withArgs(nft.target, operator.address, 20000)
      .to.emit(nft, "Transfer").withArgs(operator, zeroAddr, 100)
      .to.emit(nft, "Transfer").withArgs(operator, zeroAddr, 200);
  });

  it("pack/unpack: blocked", async function () {
    const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);
    await mt.connect(operator).mintTo(operator.address, 65000, 0);
    await mt.connect(operator).mintTo(operator.address, 65000, 0);

    await nft.connect(operator).pack(10000, 101);
    await nft.connect(operator).transferFrom(operator.address, alice.address, 101);
    await mt.connect(operator).addToBlockedList(alice.address);

    await expect(nft.connect(alice).unpack(101))
      .to.be.revertedWithCustomError(nft, "BlockedAccount")
      .withArgs(alice.address);
  });

  it("mint/redeem", async function () {
    const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);

    // prepare to mint
    await expect(nft.connect(operator).mintAndPack(10000, 101, 1))
      .to.changeTokenBalances(mt, [nft.target, operator], [0, 0]);

    await expect(nft.connect(operator).mintAndPack(10000, 101, 1))
      .to.emit(mt, "Transfer").withArgs(zeroAddr, nft.target, 10000)
      .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 101);
    await expect(nft.connect(operator).mintAndPack(20000, 101, 1))
      .to.be.revertedWithCustomError(nft, "DuplicatedBullion")
      .withArgs(101);
  
    await expect(nft.connect(operator).unpackAndRedeem(404, alice.address, "0xda7a"))
      .to.be.revertedWithCustomError(nft, "NoSuchBullion")
      .withArgs(404);
    await expect(nft.connect(operator).unpackAndRedeem(101, alice.address, "0xda7a"))
      .to.emit(mt, "Transfer").withArgs(nft.target, operator, 10000)
      .to.emit(mt, "Transfer").withArgs(operator, zeroAddr, 10000)
      .to.emit(nft, "Transfer").withArgs(operator, zeroAddr, 101);
  });

  it("unpackAndRedeem: batch", async function () {
    const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
    await mt.setNFTContract(nft.target);
    await mt.connect(operator).increaseMintBudget(2000000);

    await nft.connect(operator).mintAndPack(10000, 100, 1);
    await nft.connect(operator).mintAndPack(10000, 100, 1);
    await nft.connect(operator).mintAndPack(20000, 200, 2);
    await nft.connect(operator).mintAndPack(20000, 200, 2);

    await expect(nft.connect(operator).batchUnpackAndRedeem([100, 200], alice.address, "0xda7a"))
      .to.emit(mt, "Transfer").withArgs(nft.target, operator, 10000)
      .to.emit(mt, "Transfer").withArgs(nft.target, operator, 20000)
      .to.emit(mt, "Transfer").withArgs(operator, zeroAddr, 10000)
      .to.emit(mt, "Transfer").withArgs(operator, zeroAddr, 20000)
      .to.emit(nft, "Transfer").withArgs(operator, zeroAddr, 100)
      .to.emit(nft, "Transfer").withArgs(operator, zeroAddr, 200);
  });

  describe("packWithSig", function () {

    it("error: SignatureExpired", async function () {
      const { nft, alice } = await loadFixture(deployTestFixture);

      const [r, s, v] = await sign712Pack(alice, nft.target, alice.address, 12345, 888, 1721000000);
      await expect(nft.connect(alice).packWithSig(12345, 888, 1721000000, v, r, s))
        .to.be.revertedWithCustomError(nft, "SignatureExpired")
        .withArgs(1721000000);
    });

    it("error: InvalidSigner", async function () {
      const { nft, alice } = await loadFixture(deployTestFixture);

      const [r, s, v] = await sign712Pack(alice, nft.target, alice.address, 12345, 888, 9999999999);
      await expect(nft.connect(alice).packWithSig(12345, 888, 9999999999, v, r, s))
        .to.be.revertedWithCustomError(nft, "InvalidSigner")
        .withArgs(alice.address);
    });

    it("verify712Pack", async function() {
      const { nft, alice } = await loadFixture(deployTestFixture);

      const [r, s, v] = await sign712Pack(alice, nft.target, alice.address, 12345, 888, 9999999999);
      const addr = verify712Pack(nft.target, alice.address, 12345, 888, 9999999999, {r, s, v});
      expect(addr).to.equal(alice.address);
    });

    it("verify712Pack: sepolia tx1", async function() {
      // https://sepolia.etherscan.io/tx/0x26b1fd021790b16158b18cd4d86de1dac90bb5f7068b5ec8724d07da9260c6d6
      const addr = verify712Pack(
        "0x984e2ae5cAfbd94175CDb9359f375382446fbdC0", 
        "0x3323e6E8601a8E036AA5b8c738C8C65a48218d6c",
        "0x15779a9de6eeb00000",      // amount
        "0xde0b6b3a7640000",         // bullionId
        "0x591520393e66d6f87e40000", // deadline
        {
          r: "0x3362b2064c10799c76bf0a3def044e612056aa566c8e1c58411f91d971d99278", 
          s: "0x39cbcdb4e278d66de1225c62ae07a259908889861167e6da473fc09a3a802658", 
          v: "0x1c",
        },
        {chainId: 11155111}, // sepolia chainid
        );
      expect(addr).to.equal('0x489b3Ac25Eb4c523ed2006f64F3ce42FF0b2a1a5');
    });

    it("verify712Pack: sepolia tx2", async function() {
      // https://sepolia.etherscan.io/tx/0x103705d4af32470fc168256600a3a221f0f5ff83818e0745fb86350765e7aa0c
      const addr = verify712Pack(
        "0x984e2ae5cAfbd94175CDb9359f375382446fbdC0", 
        "0x3323e6E8601a8E036AA5b8c738C8C65a48218d6c",
        "0x15779a9de6eeb00000", // amount
        "0xde0b6b3a7640000",    // bullionId
        "0x66b57ab3",           // deadline
        {
          r: "0x37ad6012edf7b58f8eed3f33fb58b719eec6be3cbd1d973f463613b554d128c1", 
          s: "0x53caa1fdb7ef051f168f0679774da34d089755da77fc6c04d2fbce4051ba747f", 
          v: "0x1c",
        },
        {chainId: 11155111}, // sepolia chainid
        );
      expect(addr).to.equal('0x94F5D7A58B95243D5981e4DB5aCa2eBABAB375A2');
    });

    it("OK", async function () {
      const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
      await mt.setNFTContract(nft.target);
      await nft.connect(operator).setPackSigner(alice.address);
      await nft.connect(operator).setPackSigner(alice.address);
      await mt.connect(operator).increaseMintBudget(2000000);
      await mt.connect(operator).mintTo(alice.address, 65000, 0);
      await mt.connect(operator).mintTo(alice.address, 65000, 0);

      const [r, s, v] = await sign712Pack(alice, nft.target, alice.address, 12345, 888, 9999999999);
      await nft.connect(alice).packWithSig(12345, 888, 9999999999, v, r, s);
    });

  });

});
