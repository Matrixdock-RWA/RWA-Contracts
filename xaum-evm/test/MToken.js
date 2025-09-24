const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");

const zeroAddr = '0x0000000000000000000000000000000000000000';
const zeroBytes32 = '0x0000000000000000000000000000000000000000000000000000000000000000';
const fakeSolanaAddr = '0xadb988d4ab4fc55dd7069344c325e327706e1ec41f0c3db007ce32b29a4fe6ee';
const fakeSolanaAddr2 = '0x471fe8fd552fb23b3c72c774340f553e92c37e9f79b48fd9d363a491ecd65a7b';

// pad zeros to left
function addrToBytes32(addr) {
  return addr.toLowerCase().replace('0x', '0x000000000000000000000000');
}

// pad zeros to right
function addrTo32Bytes(addr) {
  return addr.toLowerCase().replace('0x', '') + '000000000000000000000000';
}

async function getTS(tx) {
  const block = await ethers.provider.getBlock(tx.blockNumber);
  return block.timestamp;
}

function calcMintToReqId(receiverAddr, amt, nonce) {
  const req = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint", "uint"], [receiverAddr, amt, nonce]);
  return ethers.keccak256(req);
}

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


describe("MTokenALL", function () {

  async function deployTestFixture() {
    const [owner, operator, packSigner, fakeNft, alice, bob] = await ethers.getSigners();

    const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
    const reserveFeed = await FallbackReserveFeed.deploy(owner.address);
    await reserveFeed.setReserve(100000000);

    const MTokenMain = await ethers.getContractFactory("MTokenMainV2");
    const mt = await upgrades.deployProxy(MTokenMain, 
      ["MTokenMain", "MTM", owner.address, operator.address, reserveFeed.target],
      {kind: "uups"}
    );

    const MTokenSide = await ethers.getContractFactory("MTokenSideV2");
    const mtSide = await upgrades.deployProxy(MTokenSide,
      ["MTokenSide", "MTS", owner.address, operator.address],
      {kind: "uups"}
    );

    const BullionNFT = await ethers.getContractFactory("BullionEnumerableNFT_UT");
    const nft = await upgrades.deployProxy(BullionNFT,
      ["BullionNFT", "BNFT", mt.target, packSigner.address, owner.address],
      {kind: "uups"}
    );

    const FakeRouterClient = await ethers.getContractFactory("FakeRouterClient");
    const ccipRouter = await FakeRouterClient.deploy();

    const FakeL0Endpoint = await ethers.getContractFactory("FakeL0Endpoint");
    const lzEndpoint = await FakeL0Endpoint.deploy();

    const MTokenMessager = await ethers.getContractFactory("MTokenMessagerV3");
    const mtMsg = await MTokenMessager.deploy(ccipRouter, mt, lzEndpoint, owner);
    const mtMsgSide = await MTokenMessager.deploy(ccipRouter, mtSide, lzEndpoint, owner);

    return {
      reserveFeed, ccipRouter, lzEndpoint, // fake
      mt, mtSide, nft, mtMsg, mtMsgSide, // contracts
      owner, operator, packSigner, fakeNft, alice, bob,
    };
  }

  describe("delayedSet", function () {
    let testCases = [ 
      {c: "mt",  field: "delay",       zeroVal: 0,        initVal: 0,        newVal: 12345},
      {c: "mt",  field: "messager",    zeroVal: zeroAddr, initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000001"},
      {c: "mt",  field: "revoker",     zeroVal: zeroAddr, initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000005"},
      {c: "mt",  field: "operator",    zeroVal: zeroAddr, initVal: "opAddr", newVal: "0x0000000000000000000000000000000000000002"},
      {c: "mt",  field: "reserveFeed", zeroVal: zeroAddr, initVal: "rfAddr", newVal: "0x0000000000000000000000000000000000000003"},
      {c: "mt",  field: "fallbackFeed",zeroVal: zeroAddr, initVal: "fbAddr", newVal: "0x0000000000000000000000000000000000000006"},
      {c: "nft", field: "packSigner",  zeroVal: zeroAddr, initVal: "psAddr", newVal: "0x0000000000000000000000000000000000000004"},
    ];

    it("setDelay: MIN_DELAY", async function () {
        const { mt } = await loadFixture(deployTestFixture);

        for (const delay of [0, 1, 43, 888, 3599]) {
          await expect(mt.setDelay(delay)).to.be.revertedWithCustomError(mt, "DelayTooSmall");
        }

        await mt.setDelay(3600); // ok
    });

    for (const {c, field, zeroVal, initVal, newVal} of testCases) {
      const _Field = field[0].toUpperCase() + field.substring(1);
      const setter = 'set' + _Field;
      const revoker = 'revokeNext' + _Field;
      const next = 'next' + _Field;
      const etNext = 'etNext' + _Field;
      const reqEvent = 'Set' + _Field + 'Request';
      const eftEvent = 'Set' + _Field + 'Effected';

      it(c + "." + setter, async function () {
        const { mt, nft, reserveFeed, operator, packSigner, alice } = await loadFixture(deployTestFixture);
        
        let _c = c == "mt" ? mt : nft.connect(operator);
        let _initVal = initVal;
        if (initVal == "opAddr") { _initVal = operator.address; }
        if (initVal == "rfAddr") { _initVal = reserveFeed.target; }
        if (initVal == "fbAddr") { _initVal = zeroAddr; }
        if (initVal == "psAddr") { _initVal = packSigner.address; }

        expect(await _c[field]()).to.equal(_initVal);
        expect(await _c[next]()).to.equal(zeroVal);
        expect(await _c[etNext]()).to.equal(0);

        const delay = 10000;
        await mt.setDelay(delay);
        await mt.setDelay(delay);
        expect(await mt.delay()).to.equal(delay);
        if (field == "delay") { _initVal = delay; }

        await expect(_c[setter](newVal))
          .to.emit(_c, reqEvent).withArgs(_initVal, newVal, anyValue);

        const tx1 = await _c[setter](newVal);
        const ts1 = await getTS(tx1);
        expect(await _c[field]()).to.equal(_initVal);
        expect(await _c[next]()).to.equal(newVal);
        expect(await _c[etNext]()).to.equal(ts1 + delay);

        const tx2 = await _c[setter](newVal);
        const ts2 = await getTS(tx2);
        expect(await _c[field]()).to.equal(_initVal);
        expect(await _c[next]()).to.equal(newVal);
        expect(await _c[etNext]()).to.equal(ts2 + delay);
      
        await time.increase(delay + 1);
        await expect(_c[setter](newVal)).to.emit(_c, eftEvent).withArgs(newVal);
        expect(await _c[field]()).to.equal(newVal);
        expect(await _c[next]()).to.equal(newVal);
        expect(await _c[etNext]()).to.equal(ts2 + delay);

        // test revode
        await mt.setRevoker(alice.address);
        await time.increase(delay * 3);
        await mt.setRevoker(alice.address);
        await _c.connect(alice)[revoker]();
        expect(await _c[etNext]()).to.equal(0);
        await expect(_c.connect(packSigner)[revoker]())
          .to.be.revertedWithCustomError(_c, "NotRevoker")
          .withArgs(packSigner.address);

        // test set by non-privileged addr
        const errType = c == "mt" ? "OwnableUnauthorizedAccount": "NotOperator";
        await expect(_c.connect(alice)[setter](newVal))
          .to.be.revertedWithCustomError(_c, errType)
          .withArgs(alice.address);

      });

    }

  });

  for (const cName of ["mt", "mtSide", "nft"]) {
    describe("upgrade: " + cName, function () {

      it("request/revoke", async function() {
        const fixture = await loadFixture(deployTestFixture);
        const {mt, mtSide, owner, alice, bob} = fixture;
        const _c = fixture[cName];
        for (const _mt of [mt, mtSide]) {
          await _mt.setRevoker(bob.address);
          await _mt.setRevoker(bob.address);
          await _mt.setDelay(100000);
          await _mt.setDelay(100000);
        }

        await expect(_c.connect(alice).requestUpgradeToAndCall(bob.address, "0xb0b0"))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        await expect(_c.connect(alice).revokeNextUpgrade())
          .to.be.revertedWithCustomError(_c, "NotRevoker")
          .withArgs(alice.address);
      
        await expect(_c.connect(owner).requestUpgradeToAndCall(bob.address, "0xb0b0"))
          .to.emit(_c, "UpgradeToAndCallRequest")
          .withArgs(bob.address, "0xb0b0");
        expect(await _c.nextImplementation()).to.equal(bob.address);
        expect(await _c.nextUpgradeToAndCallDataHash()).to.equal(ethers.keccak256("0xb0b0"));
        expect(await _c.etNextUpgradeToAndCall()).to.gt(0);

        const tx = await _c.connect(owner).requestUpgradeToAndCall(alice.address, "0xa1ce");
        const ts = await getTS(tx);
        expect(await _c.nextImplementation()).to.equal(alice.address);
        expect(await _c.nextUpgradeToAndCallDataHash()).to.equal(ethers.keccak256("0xa1ce"));
        expect(await _c.etNextUpgradeToAndCall()).to.equal(ts + 100000);

        await _c.connect(bob).revokeNextUpgrade();
        expect(await _c.etNextUpgradeToAndCall()).to.equal(0);
      });

      it("upgradeToAndCall", async function() {
        const fixture = await loadFixture(deployTestFixture);
        const {mt, mtSide, owner, alice, bob} = fixture;
        const _c = fixture[cName];
        for (const _mt of [mt, mtSide]) {
          await _mt.setRevoker(bob.address);
          await _mt.setRevoker(bob.address);
          await _mt.setDelay(100000);
          await _mt.setDelay(100000);
        }

        const NFTv2 = await ethers.getContractFactory("BullionEnumerableNFT_UT2");
        const nft2impl = await NFTv2.deploy();
        await _c.connect(owner).requestUpgradeToAndCall(nft2impl.target, "0x");

        await expect(_c.connect(owner).upgradeToAndCall(bob.address, "0x"))
          .to.be.revertedWithCustomError(_c, "InvalidUpgradeToAndCallImpl");
        await expect(_c.connect(owner).upgradeToAndCall(nft2impl.target, "0x1234"))
          .to.be.revertedWithCustomError(_c, "InvalidUpgradeToAndCallData");
        await expect(_c.connect(owner).upgradeToAndCall(nft2impl.target, "0x"))
          .to.be.revertedWithCustomError(_c, "TooEarlyToUpgradeToAndCall");

        await time.increase(100000);
        await expect(_c.connect(alice).upgradeToAndCall(nft2impl.target, "0x"))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        await _c.connect(bob).revokeNextUpgrade();
        expect(await _c.etNextUpgradeToAndCall()).to.equal(0);
        await expect(_c.connect(owner).upgradeToAndCall(nft2impl.target, "0x"))
          .to.be.revertedWithCustomError(_c, "TooEarlyToUpgradeToAndCall");

        if (cName == "nft") {
          expect(await _c.version()).to.equal(1);
        }

        // zeroAddr
        await _c.connect(owner).requestUpgradeToAndCall(zeroAddr, "0x");
        await time.increase(100000);
        await expect(_c.connect(owner).upgradeToAndCall(zeroAddr, "0x"))
          .to.be.reverted;

        // ok
        await _c.connect(owner).requestUpgradeToAndCall(nft2impl.target, "0x");
        await time.increase(100000);
        await _c.connect(owner).upgradeToAndCall(nft2impl.target, "0x");
        expect(await upgrades.erc1967.getImplementationAddress(_c.target))
          .to.equal(nft2impl.target);
        if (cName == "nft") {
          expect(await _c.version()).to.equal(2);
        }
      });

    });
  }

  it("checkZeroAddress", async function () {
      const { mt, nft, owner, operator } = await loadFixture(deployTestFixture);

      const testCases = [
        mt.connect(owner).setMessager(zeroAddr),
        mt.connect(owner).setMessager(zeroAddr),
        mt.connect(owner).setNFTContract(zeroAddr),
        mt.connect(owner).setRevoker(zeroAddr),
        mt.connect(owner).setOperator(zeroAddr),
        mt.connect(owner).setReserveFeed(zeroAddr),
        nft.connect(operator).setPackSigner(zeroAddr),
      ];

      for (const testCase of testCases) {
        await expect(testCase)
          .to.be.revertedWithCustomError(mt, "ZeroAddress");
      }
  });

  describe("MToken", function () {

    it("onlyXXX", async function () {
      const { mt, alice, bob } = await loadFixture(deployTestFixture);

      const testCases = [
        // onlyOnler
        ["OwnableUnauthorizedAccount", mt.connect(alice).setDelay(123)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setMessager(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setNFTContract(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setOperator(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setRevoker(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setDisableCcSend(true)],
        // onlyOperator
        ["NotOperator", mt.connect(alice).addToBlockedList(alice.address)],
        ["NotOperator", mt.connect(alice).removeFromBlockedList(alice.address)],
        // onlyNFTContract
        ["NotNftContract", mt.connect(alice).pack(alice.address, 123)],
        ["NotNftContract", mt.connect(alice).unpack(alice.address, 1)],
        // onlyOperatorAndNft
        ["NotOperatorNorNft", mt.connect(alice).mintTo(alice.address, 1, 2)],
        ["NotOperatorNorNft", mt.connect(alice).redeem(123, alice.address, "0x")],
        // onlyMessager
        ["NotMessager", mt.connect(alice).ccSendToken(alice.address, bob.address, 123)],
        ["NotMessager", mt.connect(alice).ccSendMintBudget(123)],
        ["NotMessager", mt.connect(alice).ccReceive("0x1234")],
        // onlyRevoker
        ["NotRevoker", mt.connect(alice).revokeRequest(ethers.keccak256("0x1234"))],
        ["NotRevoker", mt.connect(alice).revokeNextDelay()],
        ["NotRevoker", mt.connect(alice).revokeNextOperator()],
        ["NotRevoker", mt.connect(alice).revokeNextMessager()],
        ["NotRevoker", mt.connect(alice).revokeNextRevoker()],
      ];

      for (const [errType, testCase] of testCases) {
        await expect(testCase)
          .to.be.revertedWithCustomError(mt, errType)
          .withArgs(alice.address);
      }
    });

    it("setNFTContract", async function () {
      const { mt } = await loadFixture(deployTestFixture);
      expect(await mt.nftContract()).to.equal(zeroAddr);

      const nft1 = "0x000000000000000000000000000000000000fF71";
      await mt.setNFTContract(nft1);
      expect(await mt.nftContract()).to.equal(nft1);

      const nft2 = "0x000000000000000000000000000000000000ff72";
      await mt.setNFTContract(nft2);
      expect(await mt.nftContract()).to.equal(nft1);
    });

    it("blockedList", async function () {
      const { mt, operator } = await loadFixture(deployTestFixture);

      const a1 = "0x00000000000000000000000000000000000000a1";
      const a2 = "0x00000000000000000000000000000000000000a2";
      const a3 = "0x00000000000000000000000000000000000000a3";
      const a4 = "0x00000000000000000000000000000000000000a4";

      expect(await mt.isBlocked(a1)).to.equal(false);
      expect(await mt.isBlocked(a2)).to.equal(false);
      expect(await mt.isBlocked(a3)).to.equal(false);
      expect(await mt.isBlocked(a4)).to.equal(false);

      await mt.connect(operator).addToBlockedList(a1);
      await mt.connect(operator).addToBlockedList(a3);
      await mt.connect(operator).addToBlockedList(a4);
      expect(await mt.isBlocked(a1)).to.equal(true);
      expect(await mt.isBlocked(a2)).to.equal(false);
      expect(await mt.isBlocked(a3)).to.equal(true);
      expect(await mt.isBlocked(a4)).to.equal(true);

      await mt.connect(operator).removeFromBlockedList(a4);
      expect(await mt.isBlocked(a1)).to.equal(true);
      expect(await mt.isBlocked(a2)).to.equal(false);
      expect(await mt.isBlocked(a3)).to.equal(true);
      expect(await mt.isBlocked(a4)).to.equal(false);
    });

    it("pack/unpack", async function () {
      const { mt, operator, fakeNft, alice } = await loadFixture(deployTestFixture);
      await mt.setNFTContract(fakeNft.address);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      await expect(mt.connect(fakeNft).pack(alice.address, 12345))
        .to.emit(mt, "Transfer")
        .withArgs(alice.address, fakeNft.address, 12345);

      await expect(mt.connect(fakeNft).unpack(alice.address, 11223))
        .to.emit(mt, "Transfer")
        .withArgs(fakeNft.address, alice.address, 11223);
    });

    describe("mintTo/redeem", function () {
      for (const op of ["operator", "nft"]) {
        it(op, async function () {
          const { mt, operator, fakeNft, alice } = await loadFixture(deployTestFixture);
          await mt.setDelay(10000);
          await mt.setDelay(10000);
          await mt.connect(operator).increaseMintBudget(50000);
          await mt.setNFTContract(fakeNft);
          const _op = op == "operator" ? operator : fakeNft;

          // prepare to mint1
          await expect(mt.connect(_op).mintTo(alice.address, 10001, 1))
            .to.emit(mt, "MintRequest")
            .withArgs(alice.address, 10001, 1);

          // prepare to mint2
          await expect(mt.connect(_op).mintTo(alice.address, 10002, 2))
            .to.emit(mt, "MintRequest")
            .withArgs(alice.address, 10002, 2);

          // prepare to mint3
          await mt.connect(_op).mintTo(alice.address, 50001, 3);

          // not enough delay
          await expect(mt.connect(_op).mintTo(alice.address, 10002, 2))
            .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
            .withArgs(alice.address, 10002, 2);

          // not enough bugdet
          await time.increase(10000);
          await expect(mt.connect(_op).mintTo(alice.address, 50001, 3))
            .to.be.revertedWithCustomError(mt, "MintBudgetNotEnough")
            .withArgs(50000, 50001);

          // finish mint1
          await expect(mt.connect(_op).mintTo(alice.address, 10001, 1))
            .to.changeTokenBalances(mt, [zeroAddr, alice.address], [0, 10001]);
          expect(await mt.mintBudget()).to.equal(39999);

          // finish mint2
          await expect(mt.connect(_op).mintTo(alice.address, 10002, 2))
            .to.changeTokenBalances(mt, [zeroAddr, alice.address], [0, 10002]);
          expect(await mt.mintBudget()).to.equal(29997);

          // redeem1
          await mt.connect(alice).transfer(operator.address, 4321);
          await expect(mt.connect(_op).redeem(4321, alice.address, "0xc001"))
            .to.changeTokenBalances(mt, [operator.address, zeroAddr], [-4321, 0])
          expect(await mt.mintBudget()).to.equal(29997 + 4321);

          // redeem2
          await mt.connect(alice).transfer(operator.address, 1357);
          await expect(mt.connect(_op).redeem(1357, alice.address, "0xc002"))
            .to.emit(mt, "Redeem").withArgs(alice.address, 1357, "0xc002");
          expect(await mt.mintBudget()).to.equal(29997 + 4321 + 1357);
        });
      }
    });

    it("mintTo: blocked", async function () {
      const { mt, operator, fakeNft, alice } = await loadFixture(deployTestFixture);
      await mt.setDelay(10000);
      await mt.setDelay(10000);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.setNFTContract(fakeNft);
      const _op = operator;

      // block alice
      await mt.connect(operator).addToBlockedList(alice.address);
      expect(await mt.isBlocked(alice.address)).to.equal(true);

      // mintTo
      await mt.connect(_op).mintTo(alice.address, 10001, 1)
      await time.increase(10000);
      await expect(mt.connect(_op).mintTo(alice.address, 10001, 1))
        .to.changeTokenBalances(mt, [zeroAddr, alice.address], [0, 10001]);
    });

    it("revokeRequest", async function() {
      const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.setRevoker(bob.address);
      await mt.setRevoker(bob.address);

      const reqId = calcMintToReqId(alice.address, 12345, 1);
      await expect(mt.connect(alice).revokeRequest(reqId))
            .to.be.revertedWithCustomError(mt, "NotRevoker")
            .withArgs(alice.address);

      const tx1 = await mt.connect(operator).mintTo(alice.address, 10001, 1);
      const ts1 = await getTS(tx1);
      const reqId1 = calcMintToReqId(alice.address, 10001, 1);
      expect(await mt.requestMap(reqId1)).to.equal(ts1);

      await expect(await mt.connect(bob).revokeRequest(reqId1))
        .to.emit(mt, "RequestRevoked")
        .withArgs(reqId1);
      expect(await mt.requestMap(reqId1)).to.equal(0);
    });

    it("transfer", async function () {
      const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      await mt.connect(operator).addToBlockedList(alice.address);
      await expect(mt.connect(alice).transfer(bob.address, 123))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);

      await mt.connect(operator).removeFromBlockedList(alice.address);
      await expect(mt.connect(alice).transfer(mt.target, 123))
        .to.be.revertedWithCustomError(mt, "TransferToContract");

      await expect(mt.connect(alice).transfer(bob.address, 1234))
        .to.emit(mt, "Transfer")
        .withArgs(alice.address, bob.address, 1234);
    });

    it("transferFrom", async function () {
      const { mt, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(alice).approve(bob.address, 10000);

      await mt.connect(operator).addToBlockedList(alice.address);
      await expect(mt.connect(bob).transferFrom(alice.address, owner.address, 123))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);

      await mt.connect(operator).removeFromBlockedList(alice.address);
      await expect(mt.connect(bob).transferFrom(alice.address, mt.target, 123))
        .to.be.revertedWithCustomError(mt, "TransferToContract");

      await expect(mt.connect(bob).transferFrom(alice.address, owner.address, 1234))
        .to.emit(mt, "Transfer")
        .withArgs(alice.address, owner.address, 1234);
    });

    it("multiTransfer", async function () {
      const { mt, operator, alice } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      const a1 = "0x00000000000000000000000000000000000000a1";
      const a2 = "0x00000000000000000000000000000000000000a2";
      const a3 = "0x00000000000000000000000000000000000000a3";

      await expect(mt.connect(alice).multiTransfer([a1, a2, a3], [1, 2, 3, 4]))
        .to.be.revertedWithCustomError(mt, "ArgsMismatch");

      await expect(mt.connect(alice).multiTransfer([a1, a2, a3], [123, 234, 345]))
        .to.changeTokenBalances(mt, [alice.address, a1, a2, a3], [-702, 123, 234, 345])
    });

    it("msgOfCcSendToken", async function () {
      const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).addToBlockedList(alice.address);

      await expect(mt.msgOfCcSendToken(alice.address, bob.address, 123))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);
      await expect(mt.msgOfCcSendToken(bob.address, alice.address, 123))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);

      const testCases = [
        [operator.address, addrTo32Bytes(operator.address), "14"],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20"],
        [fakeSolanaAddr2, fakeSolanaAddr2.replace("0x", ""), "20"],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03"],
      ];

      for (const [receiverAddr, bytes32, lenHex] of testCases) {
        expect(await mt.msgOfCcSendToken(bob.address, receiverAddr, 0x123)).to.equal(
          "0x"
          + "0000000000000000000000000000000000000000000000000000000000000002"
          + "0000000000000000000000000000000000000000000000000000000000000040"
          + "00000000000000000000000000000000000000000000000000000000000000e0"
          + "0000000000000000000000000000000000000000000000000000000000000060"
          + "00000000000000000000000000000000000000000000000000000000000000a0"
          + "0000000000000000000000000000000000000000000000000000000000000123"
          + "0000000000000000000000000000000000000000000000000000000000000014"
          + addrTo32Bytes(bob.address)
          + "00000000000000000000000000000000000000000000000000000000000000" + lenHex
          + bytes32
        );
      }
    });

    it("msgOfCcSendMintBudget", async function () {
      const { mt, operator } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);

      await expect(mt.msgOfCcSendMintBudget(50001))
        .to.be.revertedWithCustomError(mt, "MintBudgetNotEnough")
        .withArgs(50000, 50001);
    
      expect(await mt.msgOfCcSendMintBudget(49999)).to.equal(
        "0x"
        + "0000000000000000000000000000000000000000000000000000000000000003"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000020"
        + "000000000000000000000000000000000000000000000000000000000000c34f"
      );
    });

    it("ccSendToken", async function () {
      const { mt, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.setMessager(owner);
      await mt.setMessager(owner);

      await mt.setDisableCcSend(true);
      await expect(mt.ccSendToken(alice.address, bob.address, 0))
        .to.be.revertedWithCustomError(mt, "CcSendDisabled");

      await mt.setDisableCcSend(false);
      await expect(mt.ccSendToken(alice.address, bob.address, 0))
        .to.be.revertedWithCustomError(mt, "ZeroValue");
    
      const testCases = [bob.address, fakeSolanaAddr, "0x123456"];
      for (const receiverAddr of testCases) {
        await expect(mt.ccSendToken(alice.address, receiverAddr, 123))
          .to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), 123);
  
        await expect(mt.ccSendToken(alice.address, receiverAddr, 456))
          .to.changeTokenBalances(mt, [alice.address], [-456]);
      }
    });

    it("ccSendMintBudget", async function () {
      const { mt, operator } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.setMessager(operator);
      await mt.setMessager(operator);

      await expect(mt.connect(operator).ccSendMintBudget(0))
        .to.be.revertedWithCustomError(mt, "ZeroValue");
    
      await expect(mt.connect(operator).ccSendMintBudget(10000))
        .to.emit(mt, "CCSendMintBudget")
        .withArgs(10000);
      expect(await mt.mintBudget()).to.equal(40000);

      await expect(mt.connect(operator).ccSendMintBudget(30000))
        .to.emit(mt, "CCSendMintBudget")
        .withArgs(30000);
      expect(await mt.mintBudget()).to.equal(10000);
    });

    it("ccReceiveToken: InvalidReceiver", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessager(owner);
      await mt.setMessager(owner);

      const testCases = [
        ["1234560000000000000000000000000000000000000000000000000000000000", "03", 3], // < 20 bytes
        [fakeSolanaAddr.replace("0x", ""), "20", 32], // > 20 bytes
      ];

      for (const [receiverAddr, lenHex, errArg] of testCases) {
        const msg = "0x"
          + "0000000000000000000000000000000000000000000000000000000000000002"
          + "0000000000000000000000000000000000000000000000000000000000000040"
          + "00000000000000000000000000000000000000000000000000000000000000e0"
          + "0000000000000000000000000000000000000000000000000000000000000060"
          + "00000000000000000000000000000000000000000000000000000000000000a0"
          + "0000000000000000000000000000000000000000000000000000000000000123"
          + "0000000000000000000000000000000000000000000000000000000000000020"
          + fakeSolanaAddr2.replace("0x", "") // sender
          + "00000000000000000000000000000000000000000000000000000000000000" + lenHex
          + receiverAddr // receiver
          ;
        await expect(mt.ccReceive(msg))
          .to.be.revertedWithCustomError(mt, "InvalidReceiver")
          .withArgs(errArg);
      }
    });

    it("ccReceiveToken", async function () {
      const { mt, owner, alice, bob } = await loadFixture(deployTestFixture);
      await mt.setMessager(owner);
      await mt.setMessager(owner);

      const testCases = [
        [alice.address, addrTo32Bytes(alice.address), "14"],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20"],
        [fakeSolanaAddr2, fakeSolanaAddr2.replace("0x", ""), "20"],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03"],
      ];

      for (const [senderAddr, bytes32, lenHex] of testCases) {
        const msg = "0x"
          + "0000000000000000000000000000000000000000000000000000000000000002"
          + "0000000000000000000000000000000000000000000000000000000000000040"
          + "00000000000000000000000000000000000000000000000000000000000000e0"
          + "0000000000000000000000000000000000000000000000000000000000000060"
          + "00000000000000000000000000000000000000000000000000000000000000a0"
          + "0000000000000000000000000000000000000000000000000000000000000123"
          + "00000000000000000000000000000000000000000000000000000000000000" + lenHex
          + bytes32 // sender
          + "0000000000000000000000000000000000000000000000000000000000000014"
          + addrTo32Bytes(bob.address) // receiver
          ;
  
        await expect(mt.ccReceive(msg))
          .to.emit(mt, "Transfer").withArgs(zeroAddr, bob.address, 0x123)
          .to.emit(mt, "CCReceiveToken").withArgs(senderAddr.toLowerCase(), bob.address, 0x123);
      }
    });

    it("ccReceiveMintBudget", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessager(owner);
      await mt.setMessager(owner);

      const msg = "0x"
        + "0000000000000000000000000000000000000000000000000000000000000003"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000020"
        + "000000000000000000000000000000000000000000000000000000000000c34f"
        ;

      await expect(mt.ccReceive(msg))
        .to.emit(mt, "CCReceiveMintBudget").withArgs(0xc34f);
      expect(await mt.mintBudget()).to.equal(0xc34f);
    });

    it("ccReceive: InvalidTag", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessager(owner);
      await mt.setMessager(owner);

      const msg = "0x"
        + "0000000000000000000000000000000000000000000000000000000000000004"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000020"
        + "000000000000000000000000000000000000000000000000000000000000c34f"
        ;

      await expect(mt.ccReceive(msg))
        .to.be.revertedWithCustomError(mt, "InvalidMsg")
        .withArgs(4);
    });

  });

  describe("MTokenMain", function () {

    it("init", async function () {
      const { mt, reserveFeed, owner, operator } = await loadFixture(deployTestFixture);

      expect(await mt.name()).to.equal("MTokenMain");
      expect(await mt.symbol()).to.equal("MTM");
      expect(await mt.owner()).to.equal(owner.address);
      expect(await mt.operator()).to.equal(operator.address);
      expect(await mt.reserveFeed()).to.equal(reserveFeed.target);
    
      await expect(mt.initialize("MTM2", "MTM2", owner.address, operator.address, owner.address))
        .to.be.revertedWithCustomError(mt, "InvalidInitialization");
    });

    it("updateMintBudget", async function () {
      const { mt, reserveFeed, operator, alice } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(50000);
      expect(await mt.mintBudget()).to.equal(0);
      expect(await mt.usedReserve()).to.equal(0);

      await expect(mt.connect(alice).increaseMintBudget(12345))
        .to.be.revertedWithCustomError(mt, "NotOperator")
        .withArgs(alice.address);
      await expect(mt.connect(alice).decreaseMintBudget(12345))
        .to.be.revertedWithCustomError(mt, "NotOperator")
        .withArgs(alice.address);

      await mt.connect(operator).increaseMintBudget(10000);
      expect(await mt.mintBudget()).to.equal(10000);
      expect(await mt.usedReserve()).to.equal(10000);

      await expect(mt.connect(operator).increaseMintBudget(40001))
        .to.be.revertedWithCustomError(mt, "ReserveNotEnough")
        .withArgs(50000, 50001);

      await mt.connect(operator).decreaseMintBudget(2000);
      expect(await mt.mintBudget()).to.equal(8000);
      expect(await mt.usedReserve()).to.equal(8000);
    });

    it("increaseMintBudget: fallbackFeed", async function () {
      const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);

      // reserve feed is broken
      await reserveFeed.setReserve(50000);
      await time.increase(48 * 3600);

      // no fallback feed
      await expect(mt.connect(operator).increaseMintBudget(60000))
        .to.be.reverted;

      // set fallback feed
      const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
      const fallbackFeed = await FallbackReserveFeed.deploy(owner.address);
      await fallbackFeed.setReserve(70000);
      await mt.setFallbackFeed(fallbackFeed.target);
      await mt.setFallbackFeed(fallbackFeed.target);

      // use fallback feed
      await mt.connect(operator).increaseMintBudget(60000);
      expect(await mt.mintBudget()).to.equal(60000);
      expect(await mt.usedReserve()).to.equal(60000);
    });

  });

  describe("MTokenSide", function () {

    it("init", async function () {
      const { mtSide, owner, operator } = await loadFixture(deployTestFixture);

      expect(await mtSide.name()).to.equal("MTokenSide");
      expect(await mtSide.symbol()).to.equal("MTS");
      expect(await mtSide.owner()).to.equal(owner.address);
      expect(await mtSide.operator()).to.equal(operator.address);

      await expect(mtSide.initialize("MTS2", "MTS2", operator.address, owner.address))
        .to.be.revertedWithCustomError(mtSide, "InvalidInitialization");
    });

  });

  describe("BullionNFT", function () {

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
        nft.connect(alice).batchMintAndPack([100, 200, 300], [1, 2, 3], 0),
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
        nft.connect(operator).batchMintAndPack([100, 200, 300], [1, 2, 3, 4], 1),
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

    it("mint/redeem: batch", async function () {
      const { mt, nft, operator, alice } = await loadFixture(deployTestFixture);
      await mt.setNFTContract(nft.target);
      await mt.connect(operator).increaseMintBudget(2000000);

      await nft.connect(operator).batchMintAndPack([10000, 20000], [100, 200], 1);
      await expect(nft.connect(operator).batchMintAndPack([10000, 20000], [100, 200], 1))
        .to.emit(mt, "Transfer").withArgs(zeroAddr, nft.target, 10000)
        .to.emit(mt, "Transfer").withArgs(zeroAddr, nft.target, 20000)
        .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 100)
        .to.emit(nft, "Transfer").withArgs(zeroAddr, operator, 200);

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

  describe("MTokenMessager (CCIP)", function () {

    it("init", async function () {
      const {mt, mtMsg, owner, ccipRouter} = await loadFixture(deployTestFixture);

      expect(await mtMsg.owner()).to.equal(owner.address);
      expect(await mtMsg.ccClient()).to.equal(mt.target);
      expect(await mtMsg.getRouter()).to.equal(ccipRouter.target);
    });

    it("setAllowedPeer", async function () {
      const {mtMsg, alice, bob} = await loadFixture(deployTestFixture);

      await expect(mtMsg.connect(alice).setAllowedPeer(123, bob.address, true))
        .to.be.revertedWithCustomError(mtMsg, 'OwnableUnauthorizedAccount')
        .withArgs(alice);

      const testCases = [
        [123, alice.address],
        [456, bob.address],
        [789, fakeSolanaAddr],
        [987, "0x1987"],
      ];

      // allow
      for (const [chainSelector, messager] of testCases) {
        expect(await mtMsg.allowedPeer(chainSelector, messager)).to.equal(false);
        await expect(mtMsg.setAllowedPeer(chainSelector, messager, true))
          .to.emit(mtMsg, "AllowedPeer")
          .withArgs(chainSelector, messager.toLowerCase(), true);
      }

      // disallow
      for (const [chainSelector, messager] of testCases) {
        expect(await mtMsg.allowedPeer(chainSelector, messager)).to.equal(true);
        await expect(mtMsg.setAllowedPeer(chainSelector, messager, false))
          .to.emit(mtMsg, "AllowedPeer")
          .withArgs(chainSelector, messager.toLowerCase(), false);
      }
    });

    it("error: NotInAllowListed", async function () {
      const {mtMsg, ccipRouter, alice, bob} = await loadFixture(deployTestFixture);

      await expect(mtMsg.connect(alice).sendTokenToChain(123, mtMsg.target, bob.address, 10000, "0x12"))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());

      await expect(mtMsg.connect(alice).sendMintBudgetToChain(123, mtMsg.target, 10000, "0x34"))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());

      const msgId = ethers.keccak256("0x1234");
      await expect(ccipRouter.callCcipReceive(mtMsg, [msgId, 123, mtMsg.target, "0xda7a", []]))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());
    });

    it("calcFee", async function () {
      const {mt, mtMsg, operator, alice, bob} = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);

      const testCases = [
        [mt.target, bob.address],
        [fakeSolanaAddr, fakeSolanaAddr2],
        ["0x123456", "0x7890ABCD"],
      ];

      for (const [messageReceiver, tokenReceiver] of testCases) {
        const [fee1, msg1] = await mtMsg.calculateCCSendTokenFeeAndMessage(
          123, messageReceiver, alice.address, tokenReceiver, 20000, "0x0e472a");
        expect(fee1).to.deep.equal(3200000n);
        expect(msg1[1]).to.include("0x0000000000000000000000000000000000000000000000000000000000000002");

        const [fee2, msg2] = await mtMsg.calculateCcSendMintBudgetFeeAndMessage(
          123, messageReceiver, 50000, "0x0e472a");
        expect(fee2).to.deep.equal(1280000n);
        expect(msg2[1]).to.include("0x0000000000000000000000000000000000000000000000000000000000000003");
      }
    });

    it("sendTokenToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, ccipRouter, 
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtMsg.setAllowedPeer(123, mtMsgSide.target, true);
      await mtMsgSide.setAllowedPeer(100, mtMsg.target, true);
      await mtSide.setMessager(mtMsgSide.target);
      await mtSide.setMessager(mtMsgSide.target);
      await mt.setMessager(mtMsg.target);
      await mt.setMessager(mtMsg.target);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      // ok
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, 2000, "0x0e472a",
          {value: 3200000}
        )
      ).to.emit(mt, "CCSendToken").withArgs(alice.address, bob.address.toLowerCase(), 2000)
        .to.emit(mtMsg, "CCSendToken");
      const msgId = await ccipRouter.lastMsgId();
      // console.log('msgId:', msgId);

      // return extra ether
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, 3000, "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [alice.address, ccipRouter.target], 
        [-3200000, 3200000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, 4000, "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InsufficientFee")
        .withArgs(3200000, 1900000);

      // other side
      await expect(ccipRouter.callCcipReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveToken")
        .withArgs(alice.address.toLowerCase(), bob.address, 2000);
      expect(await mt.balanceOf(alice.address)).to.equal(15000);
      expect(await mtSide.balanceOf(bob.address)).to.equal(2000);

      // more test cases
      let testCases = [
        [bob.address, addrTo32Bytes(bob.address), "14"],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20"],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03"],
      ];
      for (const [receiverAddr, bytes32, lenHex] of testCases) {
        const expectedData = '0x'
          + '0000000000000000000000000000000000000000000000000000000000000002'
          + '0000000000000000000000000000000000000000000000000000000000000040'
          + '00000000000000000000000000000000000000000000000000000000000000e0'
          + '0000000000000000000000000000000000000000000000000000000000000060'
          + '00000000000000000000000000000000000000000000000000000000000000a0'
          + '00000000000000000000000000000000000000000000000000000000000007d0'
          + '0000000000000000000000000000000000000000000000000000000000000014'
          + addrTo32Bytes(alice.address) // sender
          + '00000000000000000000000000000000000000000000000000000000000000' + lenHex
          + bytes32 // receiver
          ;
        const tx = mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, receiverAddr, 2000, "0x0e472a",
          {value: 3200000}
        );
        await tx;
        const msgId = await ccipRouter.lastMsgId();
        await expect(tx).to.emit(mtMsg, "CCSendToken")
          .withArgs(msgId, expectedData);
        await expect(tx).to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), 2000);
      }
    });

    it("sendMintBudgetToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, ccipRouter,
        operator} = await loadFixture(deployTestFixture);
      await mtMsg.setAllowedPeer(123, mtMsgSide.target, true);
      await mtMsgSide.setAllowedPeer(100, mtMsg.target, true);
      await mtSide.setMessager(mtMsgSide.target);
      await mtSide.setMessager(mtMsgSide.target);
      await mt.setMessager(mtMsg.target);
      await mt.setMessager(mtMsg.target);
      await mt.connect(operator).increaseMintBudget(50000);

      // ok
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, 5000, "0x0e472a",
          {value: 1280000}
        )
      ).to.emit(mt, "CCSendMintBudget").withArgs(5000)
        .to.emit(mtMsg, "CCSendMintBudget");
      const msgId = await ccipRouter.lastMsgId();
      // console.log('msgId:', msgId);

      // return extra ether
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, 6000, "0x0e472a",
          {value: 2000000}
        )
      ).to.changeEtherBalances(
        [operator.address, ccipRouter.target], 
        [-1280000, 1280000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, 7000, "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InsufficientFee")
        .withArgs(1280000, 1270000);
    
      // other side
      await expect(ccipRouter.callCcipReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveMintBudget")
        .withArgs(5000);
      expect(await mtSide.mintBudget()).to.equal(5000);
    });

  });

  describe("MTokenMessager (LayerZero)", function () {

    it("init", async function () {
      const {mt, mtMsg, owner, ccipRouter} = await loadFixture(deployTestFixture);

      expect(await mtMsg.owner()).to.equal(owner.address);
      expect(await mtMsg.ccClient()).to.equal(mt.target);
      expect(await mtMsg.getRouter()).to.equal(ccipRouter.target);
    });

    it("transferOwnership", async function () {
      const {mtMsg, owner, alice, bob} = await loadFixture(deployTestFixture);
      await expect(mtMsg.connect(alice).transferOwnership(bob))
        .to.be.revertedWithCustomError(mtMsg, "OwnableUnauthorizedAccount");

      await mtMsg.connect(owner).transferOwnership(bob); // ok
      expect(await mtMsg.owner()).to.equal(bob.address);
    });

    it("lzSetPeer", async function () {
      const {mtMsg, alice, bob} = await loadFixture(deployTestFixture);
      const aliceAddr32 = addrToBytes32(alice.address);
      const bobAddr32 = addrToBytes32(bob.address);
      expect(await mtMsg.peers(123)).to.equal(zeroBytes32);
      expect(await mtMsg.peers(456)).to.equal(zeroBytes32);

      await expect(mtMsg.connect(alice).lzSetPeer(123, bobAddr32))
        .to.be.revertedWithCustomError(mtMsg, 'OwnableUnauthorizedAccount')
        .withArgs(alice);

      await expect(mtMsg.lzSetPeer(123, aliceAddr32))
        .to.emit(mtMsg, "PeerSet").withArgs(123, aliceAddr32);
      await expect(mtMsg.lzSetPeer(456, bobAddr32))
        .to.emit(mtMsg, "PeerSet").withArgs(456, bobAddr32);
      expect(await mtMsg.peers(123)).to.equal(aliceAddr32);
      expect(await mtMsg.peers(456)).to.equal(bobAddr32);

      await expect(mtMsg.lzSetPeer(123, zeroBytes32))
        .to.emit(mtMsg, "PeerSet").withArgs(123, zeroBytes32);
      expect(await mtMsg.peers(123)).to.equal(zeroBytes32);
      expect(await mtMsg.peers(456)).to.equal(bobAddr32);
    });

    it("error: NoPeer", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtSide.setMessager(mtMsgSide);
      await mtSide.setMessager(mtMsgSide);
      await mt.setMessager(mtMsg);
      await mt.setMessager(mtMsg);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      await expect(mtMsg.connect(alice).lzSendTokenToChain(123, bob.address, 10000, "0x12"))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer").withArgs(123);

      await expect(mtMsg.connect(operator).lzSendMintBudgetToChain(123, 10000, "0x34"))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer").withArgs(123);

      const callLzReceiveArgs = [
        mtMsg,
        [123, addrToBytes32(alice.address), 888], // Origin
        addrToBytes32(alice.address), // _guid,
        "0x", // payload
        zeroAddr, // address
        zeroBytes32, // _data,
      ];
      await expect(lzEndpoint.callLzReceive(...callLzReceiveArgs))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer")
        .withArgs(123);
    });

    it("calcFee", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtSide.setMessager(mtMsgSide);
      await mtSide.setMessager(mtMsgSide);
      await mt.setMessager(mtMsg);
      await mt.setMessager(mtMsg);
      await mt.connect(operator).increaseMintBudget(500000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mtMsg.setPeer(123, addrToBytes32(mtMsgSide.target));

      const nativeFee2 = await mtMsg.lzCalculateSendMintBudgetFee(
        123, 50000, "0x0e472a");
      expect(nativeFee2).to.deep.equal(1280000n);

      const testCases = [bob.address, fakeSolanaAddr, "0x123456"];
      for (const receiverAddr of testCases) {
        const nativeFee1 = await mtMsg.lzCalculateSendTokenFee(
          123, alice.address, receiverAddr, 20000, "0x0e472a");
        expect(nativeFee1).to.deep.equal(3200000n);
      }
    });

    it("sendTokenToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtMsg.setPeer(123, addrToBytes32(mtMsgSide.target));
      await mtMsgSide.setPeer(100, addrToBytes32(mtMsg.target));
      await mtSide.setMessager(mtMsgSide.target);
      await mtSide.setMessager(mtMsgSide.target);
      await mt.setMessager(mtMsg.target);
      await mt.setMessager(mtMsg.target);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      // do not return extra ether
      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, 3000, "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [alice.address, lzEndpoint.target], 
        [-4000000, 4000000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, 4000, "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWith("LZ_INSUFFICIENT_FEE");

      // other side
      await mtMsg.connect(alice).lzSendTokenToChain(
        123, bob.address, 5000, "0x0e472a",
        {value: 3200000}
      );
      const msgId = await lzEndpoint.lastMsgId();
      // console.log('msgId:', msgId);
      await expect(lzEndpoint.callLzReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveToken")
        .withArgs(alice.address.toLowerCase(), bob.address, 5000);
      expect(await mt.balanceOf(alice.address)).to.equal(12000);
      expect(await mtSide.balanceOf(bob.address)).to.equal(5000);

      // more test cases
      let testCases = [
        [bob.address, addrTo32Bytes(bob.address), "14"],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20"],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03"],
      ];
      for (const [receiverAddr, bytes32, lenHex] of testCases) {
        const expectedData = '0x'
          + '0000000000000000000000000000000000000000000000000000000000000002'
          + '0000000000000000000000000000000000000000000000000000000000000040'
          + '00000000000000000000000000000000000000000000000000000000000000e0'
          + '0000000000000000000000000000000000000000000000000000000000000060'
          + '00000000000000000000000000000000000000000000000000000000000000a0'
          + '00000000000000000000000000000000000000000000000000000000000007d0'
          + '0000000000000000000000000000000000000000000000000000000000000014'
          + addrTo32Bytes(alice.address) // sender
          + '00000000000000000000000000000000000000000000000000000000000000' + lenHex
          + bytes32 // receiver
          ;
        const tx = mtMsg.connect(alice).lzSendTokenToChain(
          123, receiverAddr, 2000, "0x0e472a",
          {value: 3200000}
        );
        await tx;
        const msgId = await lzEndpoint.lastMsgId();
        await expect(tx).to.emit(mtMsg, "CCSendTokenLZ")
          .withArgs(msgId, expectedData);
        await expect(tx).to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), 2000);
      }
    });

    it("sendMintBudgetToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint,
        operator, alice} = await loadFixture(deployTestFixture);
      await mtMsg.setPeer(123, addrToBytes32(mtMsgSide.target));
      await mtMsgSide.setPeer(100, addrToBytes32(mtMsg.target));
      await mtSide.setMessager(mtMsgSide.target);
      await mtSide.setMessager(mtMsgSide.target);
      await mt.setMessager(mtMsg.target);
      await mt.setMessager(mtMsg.target);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      // ok
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, 5000, "0x0e472a",
          {value: 1280000}
        )
      ).to.emit(mt, "CCSendMintBudget").withArgs(5000)
        .to.emit(mtMsg, "CCSendMintBudgetLZ");
      const msgId = await lzEndpoint.lastMsgId();
      // console.log('msgId:', msgId);

      // do not return extra ether
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, 6000, "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [operator.address, lzEndpoint.target], 
        [-4000000, 4000000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, 7000, "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWith("LZ_INSUFFICIENT_FEE");
    
      // other side
      await expect(lzEndpoint.callLzReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveMintBudget")
        .withArgs(5000);
      expect(await mtSide.mintBudget()).to.equal(5000);
    });

    it("pause", async function () {
      const {mtMsg, owner, operator, alice, bob} = await loadFixture(deployTestFixture);

      expect(await mtMsg.lzPaused()).to.equal(false);
      await expect(mtMsg.connect(alice).setLZPaused(true))
        .to.be.revertedWithCustomError(mtMsg, "OwnableUnauthorizedAccount")
        .withArgs(alice);

      await mtMsg.connect(owner).setLZPaused(true); // ok
      expect(await mtMsg.lzPaused()).to.equal(true);

      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, 4000, "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWith("LZ_PAUSED");

      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, 7000, "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWith("LZ_PAUSED");
    });

  });

});
