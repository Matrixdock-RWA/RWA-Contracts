const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {
  deployTestFixture, getTS,
  addrTo32Bytes, scaleUp,
  zeroAddr, fakeSolanaAddr, fakeSolanaAddr2,
} = require("./MTokenTestUtils.js");


function calcMintToReqId(receiverAddr, amt, nonce) {
  const req = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint", "uint"], [receiverAddr, amt, nonce]);
  return ethers.keccak256(req);
}

describe("MTokenFT", function () {

  describe("delayedSet", function () {
    const testCases = [ 
      {c: "mt",  field: "delay",       zeroVal: 0,        initVal: 0,        newVal: 12345},
      {c: "mt",  field: "messenger",    zeroVal: zeroAddr, initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000001"},
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
        await expect(mt.setDelay(7 * 24 * 3600 + 1)).to.be.revertedWithCustomError(mt, "DelayTooLarge");

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
        const { mt, nft, reserveFeed, operator, packSigner, owner, alice } = await loadFixture(deployTestFixture);
        
        const _c = c == "mt" ? mt : nft.connect(operator);
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

        // test revoke
        await mt.setRevoker(alice.address);
        await time.increase(delay * 3);
        await mt.setRevoker(alice.address);
        await _c.connect(revoker == "revokeNextRevoker" ? owner : alice)[revoker]();
        expect(await _c[etNext]()).to.equal(0);
        await expect(_c.connect(packSigner)[revoker]())
          .to.be.revertedWithCustomError(_c, revoker == "revokeNextRevoker" ? "OwnableUnauthorizedAccount" : "NotRevoker")
          .withArgs(packSigner.address);

        // test set by non-privileged addr
        const errType = c == "mt" ? "OwnableUnauthorizedAccount": "NotOperator";
        await expect(_c.connect(alice)[setter](newVal))
          .to.be.revertedWithCustomError(_c, errType)
          .withArgs(alice.address);

      });

    }

  });

  it("checkZeroAddress", async function () {
      const { mt, nft, owner, operator } = await loadFixture(deployTestFixture);

      const testCases = [
        mt.connect(owner).setMessenger(zeroAddr),
        mt.connect(owner).setMessenger(zeroAddr),
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

  describe("MTokenBase", function () {

    it("onlyXXX", async function () {
      const { mt, alice, bob } = await loadFixture(deployTestFixture);

      const testCases = [
        // onlyOnler
        ["OwnableUnauthorizedAccount", mt.connect(alice).setDelay(123)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setMessenger(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setNFTContract(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setOperator(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setRevoker(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setDisableCcSend(true)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).revokeNextRevoker()],
        ["OwnableUnauthorizedAccount", mt.connect(alice).forcedTransfer(alice.address, bob.address, 123, "0x123456", "0x12345678")],
        // onlyOperator
        ["NotOperator", mt.connect(alice).addToBlockedList(alice.address)],
        ["NotOperator", mt.connect(alice).removeFromBlockedList(alice.address)],
        // onlyNFTContract
        ["NotNftContract", mt.connect(alice).pack(alice.address, 123)],
        ["NotNftContract", mt.connect(alice).unpack(alice.address, 1)],
        // onlyOperatorAndNft
        ["NotOperatorNorNft", mt.connect(alice).mintTo(alice.address, 1, 2)],
        ["NotOperatorNorNft", mt.connect(alice).redeem(123, alice.address, "0x")],
        // onlyMessenger
        ["NotMessenger", mt.connect(alice).ccSendToken(alice.address, bob.address, 123)],
        ["NotMessenger", mt.connect(alice).ccSendMintBudget(123)],
        ["NotMessenger", mt.connect(alice).ccReceive("0x1234")],
        // onlyRevoker
        ["NotRevoker", mt.connect(alice).revokeRequest(ethers.keccak256("0x1234"))],
        ["NotRevoker", mt.connect(alice).revokeNextDelay()],
        ["NotRevoker", mt.connect(alice).revokeNextOperator()],
        ["NotRevoker", mt.connect(alice).revokeNextMessenger()],
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

    it("forcedTransfer", async function () {
      const { mt, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      await expect(mt.connect(alice).forcedTransfer(alice.address, bob.address, 123, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, "0x123456", "0x12345678"))
        .to.emit(mt, "ForcedTransfer")
        .withArgs(alice.address, bob.address, 123, "0x123456", "0x12345678");
      expect(await mt.balanceOf(alice.address)).to.equal(20000-123);
      expect(await mt.balanceOf(bob.address)).to.equal(123);
    });

    it("msgOfCcSendToken", async function () {
      const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.connect(operator).addToBlockedList(alice.address);

      await expect(mt.msgOfCcSendToken(alice.address, bob.address, scaleUp(123)))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);
      await expect(mt.msgOfCcSendToken(bob.address, alice.address, scaleUp(123)))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);
      await expect(mt.msgOfCcSendToken(operator.address, bob.address, 123))
        .to.be.revertedWithCustomError(mt, "PrecisionLost");

      const testCases = [
        [operator.address, addrTo32Bytes(operator.address), "14"],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20"],
        [fakeSolanaAddr2, fakeSolanaAddr2.replace("0x", ""), "20"],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03"],
      ];

      for (const [receiverAddr, bytes32, lenHex] of testCases) {
        expect(await mt.msgOfCcSendToken(bob.address, receiverAddr, scaleUp(0x123))).to.equal(
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
      const { mt, reserveFeed, operator } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));

      await expect(mt.msgOfCcSendMintBudget(scaleUp(50001)))
        .to.be.revertedWithCustomError(mt, "MintBudgetNotEnough")
        .withArgs(scaleUp(50000), scaleUp(50001));

      await expect(mt.msgOfCcSendMintBudget(123))
        .to.be.revertedWithCustomError(mt, "PrecisionLost");

      expect(await mt.msgOfCcSendMintBudget(scaleUp(49999))).to.equal(
        "0x"
        + "0000000000000000000000000000000000000000000000000000000000000003"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000020"
        + "000000000000000000000000000000000000000000000000000000000000c34f"
      );
    });

    it("ccSendToken", async function () {
      const { mt, reserveFeed, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

      await mt.setDisableCcSend(true);
      await expect(mt.ccSendToken(alice.address, bob.address, 0))
        .to.be.revertedWithCustomError(mt, "CcSendDisabled");

      await mt.setDisableCcSend(false);
      await expect(mt.ccSendToken(alice.address, bob.address, 0))
        .to.be.revertedWithCustomError(mt, "ZeroValue");

      await expect(mt.ccSendToken(alice.address, bob.address, 123))
        .to.be.revertedWithCustomError(mt, "PrecisionLost");

      const testCases = [bob.address, fakeSolanaAddr, "0x123456"];
      for (const receiverAddr of testCases) {
        await expect(mt.ccSendToken(alice.address, receiverAddr, scaleUp(123)))
          .to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), scaleUp(123));
  
        await expect(mt.ccSendToken(alice.address, receiverAddr, scaleUp(456)))
          .to.changeTokenBalances(mt, [alice.address], [-scaleUp(456)]);
      }

      // blocked
      await mt.connect(operator).addToBlockedList(alice.address);
      await expect(mt.ccSendToken(alice.address, bob.address, scaleUp(123)))
        .to.be.revertedWithCustomError(mt, "BlockedAccount")
        .withArgs(alice.address);
    });

    it("ccSendMintBudget", async function () {
      const { mt, reserveFeed, operator } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.setMessenger(operator);
      await mt.setMessenger(operator);

      await expect(mt.connect(operator).ccSendMintBudget(0))
        .to.be.revertedWithCustomError(mt, "ZeroValue");

      await expect(mt.connect(operator).ccSendMintBudget(123))
        .to.be.revertedWithCustomError(mt, "PrecisionLost");
    
      await expect(mt.connect(operator).ccSendMintBudget(scaleUp(10000)))
        .to.emit(mt, "CCSendMintBudget")
        .withArgs(scaleUp(10000));
      expect(await mt.mintBudget()).to.equal(scaleUp(40000));

      await expect(mt.connect(operator).ccSendMintBudget(scaleUp(30000)))
        .to.emit(mt, "CCSendMintBudget")
        .withArgs(scaleUp(30000));
      expect(await mt.mintBudget()).to.equal(scaleUp(10000));
    });

    it("ccReceiveToken: InvalidReceiver", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

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
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

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
          .to.emit(mt, "Transfer").withArgs(zeroAddr, bob.address, scaleUp(0x123))
          .to.emit(mt, "CCReceiveToken").withArgs(senderAddr.toLowerCase(), bob.address, scaleUp(0x123));
      }
    });

    it("ccReceiveMintBudget", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

      const msg = "0x"
        + "0000000000000000000000000000000000000000000000000000000000000003"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000020"
        + "000000000000000000000000000000000000000000000000000000000000c34f"
        ;

      await expect(mt.ccReceive(msg))
        .to.emit(mt, "CCReceiveMintBudget").withArgs(scaleUp(0xc34f));
      expect(await mt.mintBudget()).to.equal(scaleUp(0xc34f));
    });

    it("ccReceive: InvalidTag", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

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

});
