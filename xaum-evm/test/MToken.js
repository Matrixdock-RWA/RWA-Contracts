const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {
  deployTestFixture, getTS, setupDelay,
  OP, forcedTransferReqId,
  addrTo32Bytes, scaleUp,
  zeroAddr, fakeSolanaAddr, fakeSolanaAddr2,
} = require("./MTokenTestUtils.js");

const DAY = 24 * 3600;

// a stand-in source-chain tx identifier; the contract only records it, never verifies it
const SRC_TX = "0x" + "ab".repeat(32);


function calcMintToReqId(receiverAddr, amt, nonce) {
  const req = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint256", "uint256"], [receiverAddr, amt, nonce]);
  return ethers.keccak256(req);
}

function calcForcedTransferReqId(from, to, value, data, extraData, nonce) {
  return forcedTransferReqId(from, to, value, nonce, data, extraData).reqHash;
}

describe("MTokenFT", function () {

  describe("delayedSet", function () {
    // delay/operator/revoker/govDelay are covered by MTokenRoles.js
    const testCases = [
      {field: "messenger",              initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000001"},
      {field: "reserveFeed",            initVal: "rfAddr", newVal: "0x0000000000000000000000000000000000000004"},
      {field: "fallbackFeed",           initVal: "fbAddr", newVal: "0x0000000000000000000000000000000000000005"},
      {field: "rateLimiter",            initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000006"},
      {field: "forcedTransferReceiver", initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000007"},
      {field: "mintBudgetSubmitter",    initVal: zeroAddr, newVal: "0x0000000000000000000000000000000000000008"},
    ];

    // MToken stores pending delayed-set info in requestMap (keyed by keccak256 of OP name).
    // Keys mirror the bytes32 constants in MToken.sol.
    const mtFieldToReqId = {
      messenger:              ethers.keccak256(ethers.toUtf8Bytes("OP_SET_MESSENGER")),
      reserveFeed:            ethers.keccak256(ethers.toUtf8Bytes("OP_SET_RESERVE_FEED")),
      fallbackFeed:           ethers.keccak256(ethers.toUtf8Bytes("OP_SET_FALLBACK_FEED")),
      rateLimiter:            ethers.keccak256(ethers.toUtf8Bytes("OP_SET_RATE_LIMITER")),
      forcedTransferReceiver: ethers.keccak256(ethers.toUtf8Bytes("OP_SET_FORCED_TRANSFER_RECEIVER")),
      mintBudgetSubmitter:    ethers.keccak256(ethers.toUtf8Bytes("OP_SET_MINT_BUDGET_SUBMITTER")),
    };

    for (const {field, initVal, newVal} of testCases) {
      const _Field = field[0].toUpperCase() + field.substring(1);
      const setter = 'set' + _Field;

      it("mt." + setter, async function () {
        const { mt, reserveFeed, alice, bob } = await loadFixture(deployTestFixture);

        let _initVal = initVal;
        if (initVal == "rfAddr") { _initVal = reserveFeed.target; }
        if (initVal == "fbAddr") { _initVal = zeroAddr; }

        expect(await mt[field]()).to.equal(_initVal);

        // one day satisfies both bounds: delay [1h, 48h] and govDelay [1d, 7d]
        const delay = DAY;
        await setupDelay(mt, delay, delay);
        expect(await mt.delay()).to.equal(delay);

        // MToken uses requestMap: pending info lives in requestMap[reqId].
        // A second call while pending reverts with TooEarlyToExecute;
        // requestMap is cleared after execution.
        const reqId = mtFieldToReqId[field];

        // initial: no pending request
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        // first call: queues, emits Request event
        const tx1 = await mt[setter](newVal);
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(mt, "DelayedOpRequest")
          .withArgs(reqId, BigInt(_initVal), BigInt(newVal), anyValue);
        expect(await mt[field]()).to.equal(_initVal);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(BigInt(ts1 + delay));

        // second call while pending: TooEarlyToExecute
        await expect(mt[setter](newVal))
          .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
          .withArgs(reqId);

        // execute after delay, requestMap entry is cleared
        await time.increase(delay + 1);
        await expect(mt[setter](newVal)).to.emit(mt, "DelayedOpEffected")
          .withArgs(reqId, BigInt(newVal));
        expect(await mt[field]()).to.equal(newVal);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        // make alice the revoker
        await mt.setRevoker(alice.address);
        await time.increase(delay * 3);
        await mt.connect(alice).acceptRevoker();

        // re-queue so there is something to revoke
        await mt[setter](newVal);
        await mt.connect(alice).revokeRequest(reqId);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        // non-revoker/non-owner can't revoke
        await expect(mt.connect(bob).revokeRequest(reqId))
          .to.be.revertedWithCustomError(mt, "NotOwnerOrRevoker")
          .withArgs(bob.address);

        // re-queue and verify owner (in addition to revoker) can also revoke (onlyOwnerOrRevoker)
        await mt[setter](newVal);
        await mt.revokeRequest(reqId); // owner
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        // non-owner can't set
        await expect(mt.connect(bob)[setter](newVal))
          .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount")
          .withArgs(bob.address);
      });

    }
  });

  describe("delayedOps", function () {

    const testCases = [
      {
        name: "enableCcSend",
        setupFunc: "disableCcSend",
        actionFunc: "enableCcSend",
        reqId: ethers.keccak256(ethers.toUtf8Bytes("OP_ENABLE_CC_SEND")),
        eftEvent: "EnableCcSend",
        stateGetter: "ccSendDisabled",
      },
      {
        name: "unpause",
        setupFunc: "pause",
        actionFunc: "unpause",
        reqId: ethers.keccak256(ethers.toUtf8Bytes("OP_UNPAUSE")),
        eftEvent: "Unpaused",
        stateGetter: "paused",
      },
    ];
    for (const { name, setupFunc, actionFunc, reqId, eftEvent, stateGetter } of testCases) {
      it(name, async function () {
        const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);

        const delay = 10000;
        await setupDelay(mt, delay, DAY);

        // initial state
        expect(await mt[stateGetter]()).to.equal(false);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        await mt.connect(operator)[setupFunc]();
        expect(await mt[stateGetter]()).to.equal(true);

        // first call: queues, emits Request event
        const tx1 = await mt[actionFunc]();
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(mt, "DelayedOpRequest").withArgs(reqId, 0, 0, anyValue);
        expect(await mt[stateGetter]()).to.equal(true);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(BigInt(ts1 + delay));

        // second call while pending: TooEarlyToExecute
        await expect(mt[actionFunc]())
          .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
          .withArgs(reqId);

        // execute after delay
        await time.increase(delay + 1);
        await expect(mt[actionFunc]()).to.emit(mt, eftEvent)
          .and.to.emit(mt, "DelayedOpEffected").withArgs(reqId, 0);
        expect(await mt[stateGetter]()).to.equal(false);
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

        // set alice as revoker (revoker rotation is gated by govDelay)
        await mt.setRevoker(alice.address);
        await time.increase(DAY + 1);
        await mt.connect(alice).acceptRevoker();

        // re-setup and re-queue so there is something to revoke
        await mt.connect(operator)[setupFunc]();
        await mt[actionFunc]();
        await mt.connect(alice).revokeRequest(reqId); // revoker can revoke
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);
        expect(await mt[stateGetter]()).to.equal(true); // still disabled/paused

        // owner can also revoke (onlyOwnerOrRevoker)
        await mt[actionFunc](); // re-queue (still disabled/paused)
        await mt.revokeRequest(reqId); // owner
        expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);
        expect(await mt[stateGetter]()).to.equal(true); // still disabled/paused

        // non-revoker can't revoke
        await mt[actionFunc](); // re-queue
        await expect(mt.connect(bob).revokeRequest(reqId))
          .to.be.revertedWithCustomError(mt, "NotOwnerOrRevoker")
          .withArgs(bob.address);

        // non-owner can't call action
        await expect(mt.connect(alice)[actionFunc]())
          .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);
      });
    }

  });

  it("checkZeroAddress", async function () {
      const { mt, nft, owner, operator } = await loadFixture(deployTestFixture);

      const testCases = [
        mt.connect(owner).setMessenger(zeroAddr),
        // mt.connect(owner).setRateLimiter(zeroAddr),
        mt.connect(owner).setNFTContract(zeroAddr),
        mt.connect(owner).setRevoker(zeroAddr),
        mt.connect(owner).setOperator(zeroAddr),
        mt.connect(owner).setReserveFeed(zeroAddr),
        mt.connect(owner).setForcedTransferReceiver(zeroAddr),
        mt.connect(owner).setMintBudgetSubmitter(zeroAddr),
        nft.connect(operator).setPackSigner(zeroAddr),
      ];

      for (const testCase of testCases) {
        await expect(testCase)
          .to.be.revertedWithCustomError(mt, "ZeroAddress");
      }
  });

  describe("operator/mintBudgetSubmitter must stay distinct", function () {

    it("both setters reject the other role's current address", async function () {
      const { mt, owner, operator, alice } = await loadFixture(deployTestFixture);

      // setMintBudgetSubmitter refuses the sitting operator
      await expect(mt.connect(owner).setMintBudgetSubmitter(operator.address))
        .to.be.revertedWithCustomError(mt, "OperatorSubmitterConflict")
        .withArgs(operator.address);

      // delay is 0 on a fresh deploy: first call queues, second one executes
      await mt.connect(owner).setMintBudgetSubmitter(alice.address);
      await mt.connect(owner).setMintBudgetSubmitter(alice.address);
      expect(await mt.mintBudgetSubmitter()).to.equal(alice.address);

      // and setOperator refuses the sitting submitter
      await expect(mt.connect(owner).setOperator(alice.address))
        .to.be.revertedWithCustomError(mt, "OperatorSubmitterConflict")
        .withArgs(alice.address);

      // neither role was disturbed by the rejections
      expect(await mt.operator()).to.equal(operator.address);
      expect(await mt.mintBudgetSubmitter()).to.equal(alice.address);
    });

    it("a conflict appearing inside the delay window blocks the execute call", async function () {
      const { mt, owner, bob } = await loadFixture(deployTestFixture);

      // one day satisfies both bounds: delay [1h, 48h] and govDelay [1d, 7d]
      await setupDelay(mt, DAY, DAY);

      // both requests are legal when queued: bob is neither the operator nor the submitter yet
      await mt.connect(owner).setMintBudgetSubmitter(bob.address);
      await mt.connect(owner).setOperator(bob.address);

      await time.increase(DAY + 1);

      // operator wins the race
      await mt.connect(owner).setOperator(bob.address);
      expect(await mt.operator()).to.equal(bob.address);

      // the matured submitter request must not slip through now that bob is the operator
      await expect(mt.connect(owner).setMintBudgetSubmitter(bob.address))
        .to.be.revertedWithCustomError(mt, "OperatorSubmitterConflict")
        .withArgs(bob.address);
      expect(await mt.mintBudgetSubmitter()).to.equal(zeroAddr);
    });

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
        ["OwnableUnauthorizedAccount", mt.connect(alice).setRateLimiter(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setForcedTransferReceiver(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).setMintBudgetSubmitter(alice.address)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).configMintBudgetPeer(1, true)],
        ["OwnableUnauthorizedAccount", mt.connect(alice).enableCcSend()],
        ["NotOwnerOrOperator", mt.connect(alice).revokeNextRevoker()],
        ["OwnableUnauthorizedAccount", mt.connect(alice).unpause()],
        ["OwnableUnauthorizedAccount", mt.connect(alice).forcedTransfer(alice.address, bob.address, 123, 111, "0x123456", "0x12345678")],
        // onlyOperator
        ["NotOperator", mt.connect(alice).pause()],
        ["NotOperator", mt.connect(alice).addToBlockedList(alice.address)],
        ["NotOperator", mt.connect(alice).removeFromBlockedList(alice.address)],
        ["NotOperator", mt.connect(alice).ccProcessRateLimitedMsg(123)],
        ["NotOperator", mt.connect(alice).ccDiscardRateLimitedMsg(456)],
        ["NotOperator", mt.connect(alice).disableCcSend()],
        ["NotOperator", mt.connect(alice).allocateMintBudgetToChain(1, 100)],
        // onlyMintBudgetSubmitter
        ["NotMintBudgetSubmitter", mt.connect(alice).reclaimMintBudgetFromChain(1, 100, SRC_TX)],
        // onlyNFTContract
        ["NotNftContract", mt.connect(alice).pack(alice.address, 123)],
        ["NotNftContract", mt.connect(alice).unpack(alice.address, 1)],
        // onlyOperatorAndNft
        ["NotOperatorNorNft", mt.connect(alice).mintTo(alice.address, 1, 2)],
        ["NotOperatorNorNft", mt.connect(alice).redeem(123, alice.address, "0x")],
        // onlyMessenger
        ["NotMessenger", mt.connect(alice).ccSendToken(alice.address, bob.address, 123)],
        ["NotMessenger", mt.connect(alice).ccReceive("0x1234")],
        // onlyOwnerOrRevoker
        ["NotOwnerOrRevoker", mt.connect(alice).revokeRequest(ethers.keccak256("0x1234"))],
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

    it("pause/unpause", async function () {
      const { mt, owner, operator, alice } = await loadFixture(deployTestFixture);

      expect(await mt.paused()).to.equal(false);

      await expect(mt.connect(alice).pause())
        .to.be.revertedWithCustomError(mt, "NotOperator")
        .withArgs(alice.address);
      await expect(mt.connect(alice).unpause())
        .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await expect(mt.connect(operator).pause())
        .to.emit(mt, "Paused").withArgs(operator.address);
      expect(await mt.paused()).to.equal(true);

      // delay=0: first call queues, second call executes
      await expect(mt.unpause()).to.emit(mt, "DelayedOpRequest").withArgs(OP("OP_UNPAUSE"), 0, 0, anyValue);
      expect(await mt.paused()).to.equal(true);
      await expect(mt.unpause()).to.emit(mt, "Unpaused");
      expect(await mt.paused()).to.equal(false);
    });

    it("unpause request cannot be pre-planted to bypass pause delay", async function () {
      const { mt, operator } = await loadFixture(deployTestFixture);
      const reqId = ethers.keccak256(ethers.toUtf8Bytes("OP_UNPAUSE"));

      const delay = 10000;
      await setupDelay(mt, delay, DAY);

      // defense 1: cannot create an unpause request while not paused
      expect(await mt.paused()).to.equal(false);
      await expect(mt.unpause()).to.be.revertedWithCustomError(mt, "NotPaused");
      expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

      // defense 2: a new pause revokes any pending unpause request
      await mt.connect(operator).pause();
      await expect(mt.unpause()).to.emit(mt, "DelayedOpRequest").withArgs(OP("OP_UNPAUSE"), 0, 0, anyValue);
      await time.increase(delay + 1); // request matures but is not executed

      // operator pauses again (new incident) — the matured request must not survive
      await expect(mt.connect(operator).pause())
        .to.emit(mt, "RequestRevoked").withArgs(reqId);
      expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

      // owner must go through the full delay again
      await expect(mt.unpause()).to.emit(mt, "DelayedOpRequest").withArgs(OP("OP_UNPAUSE"), 0, 0, anyValue);
      expect(await mt.paused()).to.equal(true);
      await expect(mt.unpause())
        .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
        .withArgs(reqId);

      await time.increase(delay + 1);
      await expect(mt.unpause()).to.emit(mt, "Unpaused");
      expect(await mt.paused()).to.equal(false);
    });

    it("enableCcSend request cannot be pre-planted to bypass disable delay", async function () {
      const { mt, operator } = await loadFixture(deployTestFixture);
      const reqId = ethers.keccak256(ethers.toUtf8Bytes("OP_ENABLE_CC_SEND"));

      const delay = 10000;
      await setupDelay(mt, delay, DAY);

      // defense 1: cannot create an enable request while cc-send is not disabled
      expect(await mt.ccSendDisabled()).to.equal(false);
      await expect(mt.enableCcSend()).to.be.revertedWithCustomError(mt, "CcSendNotDisabled");
      expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

      // defense 2: a new disable revokes any pending enable request
      await mt.connect(operator).disableCcSend();
      await expect(mt.enableCcSend()).to.emit(mt, "DelayedOpRequest").withArgs(OP("OP_ENABLE_CC_SEND"), 0, 0, anyValue);
      await time.increase(delay + 1); // request matures but is not executed

      // operator disables again (new incident) — the matured request must not survive
      await expect(mt.connect(operator).disableCcSend())
        .to.emit(mt, "RequestRevoked").withArgs(reqId);
      expect((await mt.requestMap(reqId)).effectiveTime).to.equal(0n);

      // owner must go through the full delay again
      await expect(mt.enableCcSend()).to.emit(mt, "DelayedOpRequest").withArgs(OP("OP_ENABLE_CC_SEND"), 0, 0, anyValue);
      expect(await mt.ccSendDisabled()).to.equal(true);
      await expect(mt.enableCcSend())
        .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
        .withArgs(reqId);

      await time.increase(delay + 1);
      await expect(mt.enableCcSend()).to.emit(mt, "EnableCcSend");
      expect(await mt.ccSendDisabled()).to.equal(false);
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
          await setupDelay(mt, 10000, DAY);
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
          const reqHash2 = calcMintToReqId(alice.address, 10002, 2);
          await expect(mt.connect(_op).mintTo(alice.address, 10002, 2))
            .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
            .withArgs(reqHash2);

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
      await setupDelay(mt, 10000, DAY);
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

    it("globalPause", async function () {
      const { mt, reserveFeed, owner, operator, fakeNft, alice, bob } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      // mint tokens to alice (stage + execute, delay=0)
      await mt.connect(operator).mintTo(alice.address, scaleUp(1000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(1000), 0);
      // transfer some to operator so redeem has tokens to burn
      await mt.connect(alice).transfer(operator.address, scaleUp(100));
      // approve bob for transferFrom
      await mt.connect(alice).approve(bob.address, scaleUp(500));
      // set up NFT contract for pack/unpack tests
      await mt.setNFTContract(fakeNft.address);
      // pack some tokens into fakeNft before pausing so unpack has balance
      await mt.connect(fakeNft).pack(alice.address, scaleUp(50));

      await mt.connect(operator).pause();

      await expect(mt.connect(operator).mintTo(alice.address, scaleUp(100), 1))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(operator).redeem(scaleUp(100), alice.address, "0x"))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(alice).transfer(bob.address, scaleUp(100)))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(bob).transferFrom(alice.address, bob.address, scaleUp(100)))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(fakeNft).pack(alice.address, scaleUp(10)))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(fakeNft).unpack(alice.address, scaleUp(10)))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");
      await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");

      // set messenger to owner for ccSendToken (setMessenger is not paused)
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);
      await expect(mt.ccSendToken(alice.address, bob.address, scaleUp(100)))
        .to.be.revertedWithCustomError(mt, "GlobalPaused");

      // unpause — all operations resume (delay=0: two calls needed)
      await mt.unpause();
      await mt.unpause();
      await expect(mt.connect(alice).transfer(bob.address, scaleUp(100)))
        .to.emit(mt, "Transfer").withArgs(alice.address, bob.address, scaleUp(100));
      await expect(mt.connect(fakeNft).unpack(alice.address, scaleUp(10)))
        .to.emit(mt, "Transfer").withArgs(fakeNft.address, alice.address, scaleUp(10));
    });

    it("revokeRequest", async function() {
      const { mt, operator, alice, bob } = await loadFixture(deployTestFixture);
      await mt.setRevoker(bob.address);
      await mt.connect(bob).acceptRevoker();

      const reqId = calcMintToReqId(alice.address, 12345, 1);
      await expect(mt.connect(alice).revokeRequest(reqId))
            .to.be.revertedWithCustomError(mt, "NotOwnerOrRevoker")
            .withArgs(alice.address);

      const tx1 = await mt.connect(operator).mintTo(alice.address, 10001, 1);
      const ts1 = await getTS(tx1);
      const reqId1 = calcMintToReqId(alice.address, 10001, 1);
      expect((await mt.requestMap(reqId1)).effectiveTime).to.equal(ts1);

      await expect(await mt.connect(bob).revokeRequest(reqId1))
        .to.emit(mt, "RequestRevoked")
        .withArgs(reqId1);
      expect((await mt.requestMap(reqId1)).effectiveTime).to.equal(0);

      // owner can also revoke (onlyOwnerOrRevoker)
      const tx2 = await mt.connect(operator).mintTo(alice.address, 10001, 2);
      const reqId2 = calcMintToReqId(alice.address, 10001, 2);
      expect((await mt.requestMap(reqId2)).effectiveTime).to.not.equal(0);
      await expect(await mt.revokeRequest(reqId2)) // owner
        .to.emit(mt, "RequestRevoked")
        .withArgs(reqId2);
      expect((await mt.requestMap(reqId2)).effectiveTime).to.equal(0);
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
      const delay = 10000;
      await setupDelay(mt, delay, DAY);
      await mt.connect(operator).increaseMintBudget(50000);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);
      await time.increase(delay);
      await mt.connect(operator).mintTo(alice.address, 20000, 0);

      // non-owner
      await expect(mt.connect(alice).forcedTransfer(alice.address, bob.address, 123, 1, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      // _from not blocked
      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 2, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "NotBlocked")
        .withArgs(alice.address);

      await mt.connect(operator).addToBlockedList(alice.address);

      // forcedTransferReceiver not configured yet (zero address)
      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 3, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "InvalidForcedTransferReceiver")
        .withArgs(bob.address);

      // configure forcedTransferReceiver (gated by govDelay)
      await mt.setForcedTransferReceiver(bob.address);
      await time.increase(DAY + 1);
      await mt.setForcedTransferReceiver(bob.address);
      expect(await mt.forcedTransferReceiver()).to.equal(bob.address);

      // wrong _to
      await expect(mt.connect(owner).forcedTransfer(alice.address, owner.address, 123, 4, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "InvalidForcedTransferReceiver")
        .withArgs(owner.address);

      // first call: stage the request. The args no longer fit DelayedOpRequest's uint160
      // slots, so they ride along in DelayedOpExtraData, keyed by the same reqHash.
      const ft5 = forcedTransferReqId(alice.address, bob.address, 123, 5, "0x123456", "0x12345678");
      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 5, "0x123456", "0x12345678"))
        .to.emit(mt, "DelayedOpExtraData")
        .withArgs(ft5.reqHash, OP("OP_FORCED_TRANSFER"), ft5.payload)
        .and.to.emit(mt, "DelayedOpRequest").withArgs(ft5.reqHash, 0, 0, anyValue);

      // too early to execute
      const reqHash5 = calcForcedTransferReqId(alice.address, bob.address, 123, "0x123456", "0x12345678", 5);
      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 5, "0x123456", "0x12345678"))
        .to.be.revertedWithCustomError(mt, "TooEarlyToExecute")
        .withArgs(reqHash5);

      // revoke (revoker rotation is gated by govDelay)
      await mt.setRevoker(bob.address);
      await time.increase(DAY + 1);
      await mt.connect(bob).acceptRevoker();
      await expect(mt.connect(bob).revokeRequest(reqHash5))
        .to.emit(mt, "RequestRevoked")
        .withArgs(reqHash5);
      expect((await mt.requestMap(reqHash5)).effectiveTime).to.equal(0);

      // re-stage and execute after delay
      await mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 6, "0x123456", "0x12345678");
      await time.increase(delay);
      await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 123, 6, "0x123456", "0x12345678"))
        .to.emit(mt, "ForcedTransfer")
        .withArgs(alice.address, bob.address, 123, "0x123456", "0x12345678");
      expect(await mt.balanceOf(alice.address)).to.equal(20000 - 123);
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

    it("ccSendToken", async function () {
      const { mt, reserveFeed, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

      await mt.connect(operator).disableCcSend();
      await expect(mt.ccSendToken(alice.address, bob.address, 0))
        .to.be.revertedWithCustomError(mt, "CcSendDisabled");

      await mt.enableCcSend();
      await mt.enableCcSend(); // execute (delay=0, two-call pattern)
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

    it("ccReceive: InvalidTag", async function () {
      const { mt, owner } = await loadFixture(deployTestFixture);
      await mt.setMessenger(owner);
      await mt.setMessenger(owner);

      // tag 3 (TAG_SEND_MINT_BUDGET) is reserved but no longer handled — must revert
      const testCases = [3, 4];
      for (const tag of testCases) {
        const msg = "0x"
          + ethers.toBeHex(tag, 32).replace("0x", "")
          + "0000000000000000000000000000000000000000000000000000000000000040"
          + "0000000000000000000000000000000000000000000000000000000000000020"
          + "000000000000000000000000000000000000000000000000000000000000c34f"
          ;

        await expect(mt.ccReceive(msg))
          .to.be.revertedWithCustomError(mt, "InvalidMsg")
          .withArgs(tag);
      }
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

    describe("cross-chain mintBudget: configMintBudgetPeer / allocateMintBudgetToChain / reclaimMintBudgetFromChain", function () {
      const PEER_EID = 999;

      it("configMintBudgetPeer gates sending only; the owner can enable and disable", async function () {
        const { mt, owner, operator, alice } = await loadFixture(deployTestFixture);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);

        // unregistered: granting budget is refused
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 100))
          .to.be.revertedWithCustomError(mt, "MintBudgetPeerNotSet")
          .withArgs(PEER_EID);

        await expect(mt.connect(owner).configMintBudgetPeer(PEER_EID, true))
          .to.emit(mt, "ConfigMintBudgetPeer")
          .withArgs(PEER_EID, true);
        expect((await mt.mintBudgetMap(PEER_EID)).enabled).to.equal(true);

        await expect(mt.connect(owner).configMintBudgetPeer(PEER_EID, false))
          .to.emit(mt, "ConfigMintBudgetPeer")
          .withArgs(PEER_EID, false);
        expect((await mt.mintBudgetMap(PEER_EID)).enabled).to.equal(false);

        // disabled: granting budget is refused again
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 100))
          .to.be.revertedWithCustomError(mt, "MintBudgetPeerNotSet")
          .withArgs(PEER_EID);
      });

      it("configMintBudgetPeer rejects eid 0, so no budget can be granted to a chain that does not exist", async function () {
        const { mt, owner, operator } = await loadFixture(deployTestFixture);

        await expect(mt.connect(owner).configMintBudgetPeer(0, true))
          .to.be.revertedWithCustomError(mt, "ZeroValue");
        await expect(mt.connect(owner).configMintBudgetPeer(0, false))
          .to.be.revertedWithCustomError(mt, "ZeroValue");

        // eid 0 therefore stays unregistered and cannot be granted budget
        await expect(mt.connect(operator).allocateMintBudgetToChain(0, 100))
          .to.be.revertedWithCustomError(mt, "MintBudgetPeerNotSet")
          .withArgs(0);
      });

      it("reclaimMintBudgetFromChain ignores the allowlist: a disabled chain can still return budget", async function () {
        const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);

        // Ethereum's own budget gives the floor a non-zero value to bite against
        await mt.connect(operator).increaseMintBudget(scaleUp(5000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 5000);
        expect(await mt.usedReserve()).to.equal(scaleUp(10000));

        // the chain is taken off the allowlist while it still holds granted budget
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, false);
        expect((await mt.mintBudgetMap(PEER_EID)).enabled).to.equal(false);

        // booking its return must still work, or that obligation is stranded in
        // usedReserve with no way out
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 2000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 2000, 2000, scaleUp(8000), SRC_TX);
        expect(await mt.usedReserve()).to.equal(scaleUp(8000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(2000);

        // and it still works while globally paused: the upstream redemption
        // happens on the side chain, which Ethereum's pause cannot stop either
        await mt.connect(operator).pause();
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 3000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 1000, 3000, scaleUp(7000), SRC_TX);
        expect(await mt.usedReserve()).to.equal(scaleUp(7000));

        // every other guard is untouched by the removed allowlist check — still disabled
        // and still paused for all of these
        await expect(mt.connect(operator).reclaimMintBudgetFromChain(PEER_EID, 4000, SRC_TX))
          .to.be.revertedWithCustomError(mt, "NotMintBudgetSubmitter")
          .withArgs(operator.address);
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 3000, SRC_TX))
          .to.be.revertedWithCustomError(mt, "StaleMintBudgetSubmission")
          .withArgs(3000, 3000);
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 4000, "0x"))
          .to.be.revertedWithCustomError(mt, "InvalidSrcTxHash")
          .withArgs(0);
        // a cumulative total whose delta exceeds usedReserve panics on the uint112
        // subtraction, before the floor check is reached
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 20000, SRC_TX))
          .to.be.revertedWithPanic(0x11);
        expect(await mt.usedReserve()).to.equal(scaleUp(7000));
      });

      it("reclaimMintBudgetFromChain works for a chain that was never registered", async function () {
        const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        const UNREGISTERED_EID = 1234;
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);

        // usedReserve is a single global ledger, so an obligation booked under one eid
        // can be returned under another that was never registered — the check is gone,
        // not merely satisfied
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 5000);
        expect((await mt.mintBudgetMap(UNREGISTERED_EID)).enabled).to.equal(false);

        await expect(mt.connect(alice).reclaimMintBudgetFromChain(UNREGISTERED_EID, 1000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, UNREGISTERED_EID, 1000, 1000, scaleUp(4000), SRC_TX);
        expect(await mt.usedReserve()).to.equal(scaleUp(4000));
        expect((await mt.mintBudgetMap(UNREGISTERED_EID)).totalReturnedAmount).to.equal(1000);
      });

      it("allocateMintBudgetToChain: grows usedReserve (PoR-bound), never touches local mintBudget", async function () {
        const { mt, reserveFeed, owner, operator } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);

        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 0))
          .to.be.revertedWithCustomError(mt, "StaleMintBudgetSubmission")
          .withArgs(0, 0);

        const tx = await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 10000);
        await expect(tx)
          .to.emit(mt, "AllocateMintBudgetToChain")
          .withArgs(operator.address, PEER_EID, 10000, 10000, scaleUp(10000)); // usedReserve is emitted in local decimals

        expect(await mt.usedReserve()).to.equal(scaleUp(10000));
        expect(await mt.mintBudget()).to.equal(0);
        expect((await mt.mintBudgetMap(PEER_EID)).totalAllocatedAmount).to.equal(10000);

        // the argument is the new cumulative total, not this call's increment: 15000
        // grants 5000 more, and the event reports both the delta and the new total
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 15000))
          .to.emit(mt, "AllocateMintBudgetToChain")
          .withArgs(operator.address, PEER_EID, 5000, 15000, scaleUp(15000));
        expect(await mt.usedReserve()).to.equal(scaleUp(15000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalAllocatedAmount).to.equal(15000);

        // a replayed instruction re-states a total already reached: reverts instead of
        // granting a second time, per the cumulative semantics
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 15000))
          .to.be.revertedWithCustomError(mt, "StaleMintBudgetSubmission")
          .withArgs(15000, 15000);
        expect(await mt.usedReserve()).to.equal(scaleUp(15000));

        // PoR ceiling enforced the same way as increaseMintBudget
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 999999))
          .to.be.revertedWithCustomError(mt, "ReserveNotEnough");
      });

      it("reclaimMintBudgetFromChain: releases usedReserve, bounded by the totalSupply+mintBudget floor", async function () {
        const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);

        // floor = totalSupply(0) + mintBudget(5000); 6000 is allocated out to the peer
        await mt.connect(operator).increaseMintBudget(scaleUp(5000));
        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 6000);
        expect(await mt.usedReserve()).to.equal(scaleUp(11000));

        // a normal reclaim, well clear of the floor
        const tx = await mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 2000, SRC_TX);
        await expect(tx)
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 2000, 2000, scaleUp(9000), SRC_TX); // usedReserve is emitted in local decimals

        expect(await mt.usedReserve()).to.equal(scaleUp(9000));
        expect(await mt.mintBudget()).to.equal(scaleUp(5000)); // untouched by the cross-chain move
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(2000);

        // repeat/stale submission reverts, so off-chain can't read it as applied
        const usedReserveBefore = await mt.usedReserve();
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 2000, SRC_TX))
          .to.be.revertedWithCustomError(mt, "StaleMintBudgetSubmission")
          .withArgs(2000, 2000);
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 1999, SRC_TX))
          .to.be.revertedWithCustomError(mt, "StaleMintBudgetSubmission")
          .withArgs(2000, 1999);
        expect(await mt.usedReserve()).to.equal(usedReserveBefore);

        // landing exactly on the floor is allowed
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 6000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 4000, 6000, scaleUp(5000), SRC_TX);
        expect(await mt.usedReserve()).to.equal(scaleUp(5000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(6000);

        // one more unit would put usedReserve below totalSupply+mintBudget: whole tx fails,
        // and neither usedReserve nor the watermark moves
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 6001, SRC_TX))
          .to.be.revertedWithCustomError(mt, "UsedReserveBelowFloor")
          .withArgs(scaleUp(4999), scaleUp(5000));
        expect(await mt.usedReserve()).to.equal(scaleUp(5000));
        expect(await mt.mintBudget()).to.equal(scaleUp(5000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(6000);

        // an outright underflow of usedReserve still reverts before the floor check
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 11001, SRC_TX))
          .to.be.revertedWithPanic(0x11);
        expect(await mt.usedReserve()).to.equal(scaleUp(5000));
      });

      it("reclaimMintBudgetFromChain: the floor counts Ethereum's totalSupply, not just its mintBudget", async function () {
        const { mt, reserveFeed, owner, operator, alice, bob } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);

        // minting moves 2000 out of Ethereum's mintBudget and into its totalSupply, so the
        // floor total is unchanged at 5000 but is now split across both terms (delay=0:
        // two calls to execute)
        await mt.connect(operator).increaseMintBudget(scaleUp(5000));
        await mt.connect(operator).mintTo(bob.address, scaleUp(2000), 0);
        await mt.connect(operator).mintTo(bob.address, scaleUp(2000), 0);
        expect(await mt.totalSupply()).to.equal(scaleUp(2000));
        expect(await mt.mintBudget()).to.equal(scaleUp(3000));

        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 4000);
        expect(await mt.usedReserve()).to.equal(scaleUp(9000));

        // landing at 3500 clears mintBudget(3000) on its own but breaches
        // totalSupply(2000)+mintBudget(3000): a floor that ignored totalSupply would let
        // this through
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 5500, SRC_TX))
          .to.be.revertedWithCustomError(mt, "UsedReserveBelowFloor")
          .withArgs(scaleUp(3500), scaleUp(5000));

        // and one unit below the floor is refused just the same
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 4001, SRC_TX))
          .to.be.revertedWithCustomError(mt, "UsedReserveBelowFloor")
          .withArgs(scaleUp(4999), scaleUp(5000));

        // neither failure moved usedReserve or the per-source watermark
        expect(await mt.usedReserve()).to.equal(scaleUp(9000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(0);

        // landing exactly on totalSupply+mintBudget is allowed
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 4000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 4000, 4000, scaleUp(5000), SRC_TX);
        expect(await mt.usedReserve()).to.equal(scaleUp(5000));
        expect(await mt.totalSupply()).to.equal(scaleUp(2000));
        expect(await mt.mintBudget()).to.equal(scaleUp(3000));
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(4000);
      });

      it("global pause blocks granting budget but never returning it", async function () {
        const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 5000);

        await mt.connect(operator).pause();

        // risk-raising: blocked
        await expect(mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 6000))
          .to.be.revertedWithCustomError(mt, "GlobalPaused");

        // risk-reducing, and its upstream is a redemption on the side chain that this
        // chain's pause cannot stop — so it must stay open
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 3000, SRC_TX))
          .to.emit(mt, "ReclaimMintBudgetFromChain");
        expect((await mt.mintBudgetMap(PEER_EID)).totalReturnedAmount).to.equal(3000);
      });

      it("global pause covers Ethereum's own increase/decreaseMintBudget", async function () {
        const { mt, reserveFeed, owner, operator } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(operator).increaseMintBudget(scaleUp(5000));

        await mt.connect(operator).pause();

        await expect(mt.connect(operator).increaseMintBudget(scaleUp(1000)))
          .to.be.revertedWithCustomError(mt, "GlobalPaused");
        // decrease is risk-reducing, but its upstream is this chain's own redemption,
        // which the pause already stops — including it seals off no exit
        await expect(mt.connect(operator).decreaseMintBudget(scaleUp(1000)))
          .to.be.revertedWithCustomError(mt, "GlobalPaused");
      });

      it("srcTxHash: rejects empty and over-long, accepts any other length unverified", async function () {
        const { mt, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        await mt.connect(owner).configMintBudgetPeer(PEER_EID, true);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(operator).allocateMintBudgetToChain(PEER_EID, 10000);

        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 100, "0x"))
          .to.be.revertedWithCustomError(mt, "InvalidSrcTxHash")
          .withArgs(0);
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 100, "0x" + "cd".repeat(129)))
          .to.be.revertedWithCustomError(mt, "InvalidSrcTxHash")
          .withArgs(129);

        // a Solana-length (64-byte) identifier is recorded as-is: the contract can't
        // read the source chain, so it never judges whether the hash is real
        const solanaSig = "0x" + "ef".repeat(64);
        await expect(mt.connect(alice).reclaimMintBudgetFromChain(PEER_EID, 100, solanaSig))
          .to.emit(mt, "ReclaimMintBudgetFromChain")
          .withArgs(alice.address, PEER_EID, 100, 100, anyValue, solanaSig);
      });
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

    describe("cross-chain mintBudget: returnMintBudgetToEth / claimMintBudgetFromEth", function () {
      const SIDE_EID = 30102; // this side chain's own eid

      it("onlyXXX", async function () {
        const { mtSide, alice } = await loadFixture(deployTestFixture);
        await expect(mtSide.connect(alice).returnMintBudgetToEth(100))
          .to.be.revertedWithCustomError(mtSide, "NotOperator")
          .withArgs(alice.address);
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 100, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "NotMintBudgetSubmitter")
          .withArgs(alice.address);
      });

      it("setLocalEid: owner-only, and both mintBudget directions fail closed until it is set", async function () {
        const { mtSide, owner, operator, alice } = await loadFixture(deployTestFixture);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);

        // unset: a chain that hasn't declared which chain it is credits nothing
        expect(await mtSide.localEid()).to.equal(0);
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 100, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "LocalEidNotSet");

        // ...and returns nothing either: the check runs before the stale/budget checks,
        // so nothing is written and no unattributable event can be emitted
        await expect(mtSide.connect(operator).returnMintBudgetToEth(100))
          .to.be.revertedWithCustomError(mtSide, "LocalEidNotSet");
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(0);

        await expect(mtSide.connect(alice).setLocalEid(SIDE_EID))
          .to.be.revertedWithCustomError(mtSide, "OwnableUnauthorizedAccount");
        // zero is rejected so that "unset" stays distinguishable
        await expect(mtSide.connect(owner).setLocalEid(0))
          .to.be.revertedWithCustomError(mtSide, "ZeroValue");

        await expect(mtSide.connect(owner).setLocalEid(SIDE_EID))
          .to.emit(mtSide, "SetLocalEid")
          .withArgs(SIDE_EID);
        expect(await mtSide.localEid()).to.equal(SIDE_EID);

        // correctable while no mintBudget has moved yet: a mistyped eid is not permanent
        const OTHER_EID = 30184;
        await expect(mtSide.connect(owner).setLocalEid(OTHER_EID))
          .to.emit(mtSide, "SetLocalEid")
          .withArgs(OTHER_EID);
        expect(await mtSide.localEid()).to.equal(OTHER_EID);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);
        expect(await mtSide.localEid()).to.equal(SIDE_EID);
      });

      it("setLocalEid: locked once an allocation watermark exists, but the same eid stays idempotent", async function () {
        const { mtSide, owner, alice } = await loadFixture(deployTestFixture);
        const OTHER_EID = 30184;
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        await mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 10000, SRC_TX);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(10000);

        // a new identity would start from a zeroed watermark pair under the new eid while
        // mintBudget still holds what arrived under this one — Ethereum keeps counting
        // against SIDE_EID, so the two sides would diff against unrelated totals
        await expect(mtSide.connect(owner).setLocalEid(OTHER_EID))
          .to.be.revertedWithCustomError(mtSide, "LocalEidLocked")
          .withArgs(SIDE_EID, OTHER_EID);
        expect(await mtSide.localEid()).to.equal(SIDE_EID);

        // re-setting the same eid is not a change, so it is still allowed
        await expect(mtSide.connect(owner).setLocalEid(SIDE_EID))
          .to.emit(mtSide, "SetLocalEid")
          .withArgs(SIDE_EID);
        expect(await mtSide.localEid()).to.equal(SIDE_EID);

        // zero and owner checks still run ahead of the lock
        await expect(mtSide.connect(owner).setLocalEid(0))
          .to.be.revertedWithCustomError(mtSide, "ZeroValue");
        await expect(mtSide.connect(alice).setLocalEid(OTHER_EID))
          .to.be.revertedWithCustomError(mtSide, "OwnableUnauthorizedAccount");

        // the watermarks are never reset by any of this
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(10000);
      });

      it("setLocalEid: locked by the return watermark alone, with totalAllocatedAmount still 0", async function () {
        const { mtSide, owner, operator, alice } = await loadFixture(deployTestFixture);
        const OTHER_EID = 30184;
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        // fund the operator over the token bridge, which mints without consuming
        // mintBudget and never touches the mintBudget watermarks (ccReceiveToken skips the budget
        // check by design), so the allocation watermark stays at 0 throughout
        await mtSide.connect(owner).setMessenger(owner);
        await mtSide.connect(owner).setMessenger(owner);
        const coder = ethers.AbiCoder.defaultAbiCoder();
        const body = coder.encode(
          ["bytes", "bytes", "uint256"],
          [alice.address, operator.address, 10000]); // value in shared decimals
        await expect(mtSide.connect(owner).ccReceive(coder.encode(["uint256", "bytes"], [2, body])))
          .to.emit(mtSide, "CCReceiveToken")
          .withArgs(alice.address.toLowerCase(), operator.address, scaleUp(10000));
        expect(await mtSide.balanceOf(operator.address)).to.equal(scaleUp(10000));
        expect(await mtSide.mintBudget()).to.equal(0);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(0);

        // redeeming operator-owned tokens credits local mintBudget, still without any
        // allocation from Ethereum
        await mtSide.connect(operator).redeem(scaleUp(10000), alice.address, "0x");
        expect(await mtSide.mintBudget()).to.equal(scaleUp(10000));
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(0);

        // now only the return watermark advances
        await mtSide.connect(operator).returnMintBudgetToEth(4000);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(4000);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(0);

        // ...and that alone is enough to freeze the identity
        await expect(mtSide.connect(owner).setLocalEid(OTHER_EID))
          .to.be.revertedWithCustomError(mtSide, "LocalEidLocked")
          .withArgs(SIDE_EID, OTHER_EID);
        expect(await mtSide.localEid()).to.equal(SIDE_EID);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(4000);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(0);
      });

      it("dstEid: a submission meant for another side chain is rejected, not credited", async function () {
        const { mtSide, owner, alice } = await loadFixture(deployTestFixture);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        // prepared for a different chain but delivered here — must fail rather than be
        // taken for this chain's own cumulative value
        const OTHER_EID = 30184;
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(OTHER_EID, 10000, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "WrongTargetChain")
          .withArgs(SIDE_EID, OTHER_EID);
        expect(await mtSide.mintBudget()).to.equal(0);
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(0);

        // the same submission addressed to this chain goes through
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 10000, SRC_TX))
          .to.emit(mtSide, "ClaimMintBudgetFromEth")
          .withArgs(alice.address, SIDE_EID, 10000, 10000, SRC_TX);
      });

      it("srcTxHash: rejects empty and over-long", async function () {
        const { mtSide, owner, alice } = await loadFixture(deployTestFixture);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 100, "0x"))
          .to.be.revertedWithCustomError(mtSide, "InvalidSrcTxHash")
          .withArgs(0);
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 100, "0x" + "cd".repeat(129)))
          .to.be.revertedWithCustomError(mtSide, "InvalidSrcTxHash")
          .withArgs(129);
      });

      it("returnMintBudgetToEth: reduces local mintBudget, tracks the cumulative return (shared decimals throughout)", async function () {
        const { mtSide, owner, operator } = await loadFixture(deployTestFixture);
        // give the side chain some local mintBudget to return (via a fabricated submitter credit)
        await mtSide.connect(owner).setMintBudgetSubmitter(owner.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(owner.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);
        await mtSide.connect(owner).claimMintBudgetFromEth(SIDE_EID, 10000, SRC_TX);
        expect(await mtSide.mintBudget()).to.equal(scaleUp(10000));

        await expect(mtSide.connect(operator).returnMintBudgetToEth(0))
          .to.be.revertedWithCustomError(mtSide, "StaleMintBudgetSubmission")
          .withArgs(0, 0);
        // input is shared decimals now: 10001 > the 10000 (shared-equivalent) budget on hand
        await expect(mtSide.connect(operator).returnMintBudgetToEth(10001))
          .to.be.revertedWithCustomError(mtSide, "MintBudgetNotEnough")
          .withArgs(scaleUp(10000), scaleUp(10001));

        // the event carries this chain's own eid, so the return-side stream is
        // filterable per chain exactly like the claim side
        const tx = await mtSide.connect(operator).returnMintBudgetToEth(4000);
        await expect(tx)
          .to.emit(mtSide, "ReturnMintBudgetToEth")
          .withArgs(operator.address, SIDE_EID, 4000, 4000);

        expect(await mtSide.mintBudget()).to.equal(scaleUp(6000));
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(4000);

        // the argument is the new cumulative total: 6500 returns 2500 more
        await expect(mtSide.connect(operator).returnMintBudgetToEth(6500))
          .to.emit(mtSide, "ReturnMintBudgetToEth")
          .withArgs(operator.address, SIDE_EID, 2500, 6500);
        expect(await mtSide.mintBudget()).to.equal(scaleUp(3500));
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(6500);

        // a replayed instruction reverts instead of returning a second time
        await expect(mtSide.connect(operator).returnMintBudgetToEth(6500))
          .to.be.revertedWithCustomError(mtSide, "StaleMintBudgetSubmission")
          .withArgs(6500, 6500);
        expect(await mtSide.mintBudget()).to.equal(scaleUp(3500));

        // does NOT respect whenNotPaused (deliberate: it's the risk-reducing
        // direction) — and it still emits the fully attributed event while paused
        await mtSide.connect(operator).pause();
        await expect(mtSide.connect(operator).returnMintBudgetToEth(7000))
          .to.emit(mtSide, "ReturnMintBudgetToEth")
          .withArgs(operator.address, SIDE_EID, 500, 7000);
        expect(await mtSide.mintBudget()).to.equal(scaleUp(3000));
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount).to.equal(7000);
      });

      it("claimMintBudgetFromEth: increases local mintBudget, tracks the cumulative allocation, reverts on stale input", async function () {
        const { mtSide, owner, operator, alice } = await loadFixture(deployTestFixture);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        const tx = await mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 10000, SRC_TX);
        await expect(tx)
          .to.emit(mtSide, "ClaimMintBudgetFromEth")
          .withArgs(alice.address, SIDE_EID, 10000, 10000, SRC_TX);

        expect(await mtSide.mintBudget()).to.equal(scaleUp(10000));
        expect((await mtSide.mintBudgetMap(SIDE_EID)).totalAllocatedAmount).to.equal(10000);

        // repeat/stale submission reverts, so off-chain can't read it as applied
        const mintBudgetBefore = await mtSide.mintBudget();
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 10000, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "StaleMintBudgetSubmission")
          .withArgs(10000, 10000);
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 9999, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "StaleMintBudgetSubmission")
          .withArgs(10000, 9999);
        expect(await mtSide.mintBudget()).to.equal(mintBudgetBefore);

        // respects whenNotPaused
        await mtSide.connect(operator).pause();
        await expect(mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, 20000, SRC_TX))
          .to.be.revertedWithCustomError(mtSide, "GlobalPaused");
      });

      it("round-trips with MTokenMain's cumulative counters using the same 9-decimal units, no manual scaling", async function () {
        const { mt, mtSide, reserveFeed, owner, operator, alice } = await loadFixture(deployTestFixture);
        await reserveFeed.setReserve(scaleUp(100000));
        const usedReserveBefore = await mt.usedReserve();
        const mintBudgetBefore = await mt.mintBudget();
        const ETH_EID = 1;
        await mt.connect(owner).configMintBudgetPeer(ETH_EID, true); // arbitrary peer slot representing this side chain
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mt.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setMintBudgetSubmitter(alice.address);
        await mtSide.connect(owner).setLocalEid(SIDE_EID);

        // Ethereum allocates budget to the side chain
        await mt.connect(operator).allocateMintBudgetToChain(ETH_EID, 7000);
        const ethTotalAllocated = (await mt.mintBudgetMap(ETH_EID)).totalAllocatedAmount;
        await mtSide.connect(alice).claimMintBudgetFromEth(SIDE_EID, ethTotalAllocated, SRC_TX);
        expect(await mtSide.mintBudget()).to.equal(scaleUp(7000));

        // side chain returns some of it back; both sides state cumulative totals, so the
        // side chain's totalReturnedAmount feeds straight into Ethereum's own totalReturnedAmount
        await mtSide.connect(operator).returnMintBudgetToEth(2000);
        const sideTotalReturned = (await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount;
        await mt.connect(alice).reclaimMintBudgetFromChain(ETH_EID, sideTotalReturned, SRC_TX);

        expect((await mt.mintBudgetMap(ETH_EID)).totalReturnedAmount).to.equal(sideTotalReturned);
        expect(await mt.usedReserve()).to.equal(scaleUp(5000));

        // and once the side chain returns the rest, the full loop nets to no real change:
        // usedReserve and Ethereum's own mintBudget are back where they started
        await mtSide.connect(operator).returnMintBudgetToEth(7000);
        const sideTotalReturnedFinal = (await mtSide.mintBudgetMap(SIDE_EID)).totalReturnedAmount;
        await mt.connect(alice).reclaimMintBudgetFromChain(ETH_EID, sideTotalReturnedFinal, SRC_TX);

        expect(await mtSide.mintBudget()).to.equal(0);
        expect((await mt.mintBudgetMap(ETH_EID)).totalReturnedAmount).to.equal(sideTotalReturnedFinal);
        expect((await mt.mintBudgetMap(ETH_EID)).totalAllocatedAmount).to.equal(sideTotalReturnedFinal);
        expect(await mt.usedReserve()).to.equal(usedReserveBefore);
        expect(await mt.mintBudget()).to.equal(mintBudgetBefore);
      });
    });

  });

});
