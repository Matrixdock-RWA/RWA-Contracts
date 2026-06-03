const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const {
  deployTestFixture,
  addrTo32Bytes, scaleUp,
  zeroAddr,
} = require("./MTokenTestUtils.js");

const FAKE_DST_EID = 1;

function makeCcSendTokenMsg(sender, receiver, amount) {
  return '0x'
    + '0000000000000000000000000000000000000000000000000000000000000002'
    + '0000000000000000000000000000000000000000000000000000000000000040'
    + '00000000000000000000000000000000000000000000000000000000000000e0'
    + '0000000000000000000000000000000000000000000000000000000000000060'
    + '00000000000000000000000000000000000000000000000000000000000000a0'
    + amount.toString(16).padStart(64, '0')
    + '0000000000000000000000000000000000000000000000000000000000000014'
    + addrTo32Bytes(sender)
    + '0000000000000000000000000000000000000000000000000000000000000014'
    + addrTo32Bytes(receiver)
    ;
}

function correctTime([inflight, capacity]) {
  const delta = capacity % (10n ** 10n);
  return [inflight + delta, capacity - delta];
}

async function setupRateLimiter(mt, rateLimiter, operator) {
  await mt.setMessenger(operator.address);
  await mt.setMessenger(operator.address);
  await mt.setRateLimiter(rateLimiter.target);
  await mt.setRateLimiter(rateLimiter.target);
  mt.ccReceiveToken = function(from, to, amount) {
    const msg = makeCcSendTokenMsg(from, to, amount);
    return mt.connect(operator).ccReceive(msg);
  };
}

describe("MTokenRateLimiter", function () {

  it("setRateLimit", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([0, 0]);

    await expect(rateLimiter.connect(alice).setRateLimit(10000, 3600))
      .to.be.revertedWithCustomError(rateLimiter, "NotMTokenOwner")
      .withArgs(alice.address);

    await expect(rateLimiter.setRateLimit(10000, 3600))
      .to.emit(rateLimiter, "RateLimitsChanged")
      .withArgs([[FAKE_DST_EID, 10000, 3600]]);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([10000, 3600]);

    await expect(rateLimiter.setRateLimit(20000, 4800))
      .to.emit(rateLimiter, "RateLimitsChanged")
      .withArgs([[FAKE_DST_EID, 20000, 4800]]);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([20000, 4800]);
  });

  it("setSingleMsgLimit", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);
    await expect(rateLimiter.connect(alice).setSingleMsgLimit(1000))
      .to.be.revertedWithCustomError(rateLimiter, "NotMTokenOwner")
      .withArgs(alice.address);

    await expect(rateLimiter.setSingleMsgLimit(1000))
      .to.emit(rateLimiter, "SingleMsgLimitUpdated")
      .withArgs(1000);
    expect(await rateLimiter.singleMsgLimit()).to.equal(1000);
  });

  it("updateWhitelist", async function () {
    const { rateLimiter, alice, bob } = await loadFixture(deployTestFixture);
    const aliceBytes = alice.address.toLowerCase();

    await expect(rateLimiter.connect(alice).updateWhitelist(aliceBytes, bob.address, true))
      .to.be.revertedWithCustomError(rateLimiter, "NotMTokenOwner")
      .withArgs(alice.address);

    await expect(rateLimiter.updateWhitelist(aliceBytes, bob.address, true))
      .to.emit(rateLimiter, "WhitelistUpdated")
      .withArgs(aliceBytes, bob.address, true);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(true);

    await expect(rateLimiter.updateWhitelist(aliceBytes, bob.address, false))
      .to.emit(rateLimiter, "WhitelistUpdated")
      .withArgs(aliceBytes, bob.address, false);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(false);
  });

  it("checkAndUpdateRateLimit: notMToken", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);
    await expect(rateLimiter.connect(alice).checkAndUpdateRateLimit(alice.address, 123, "0x123456"))
      .to.be.revertedWithCustomError(rateLimiter, "NotMToken")
      .withArgs(alice.address);
  });

  it("checkAndUpdateRateLimit: consume", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);

    await mt.ccReceiveToken(alice.address, bob.address, 1000);
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(1000), scaleUp(9000)]);

    await mt.ccReceiveToken(alice.address, bob.address, 2000);
    expect(await rateLimiter.amountCanBeReceived().then(x => correctTime(x)))
      .to.deep.equal([scaleUp(3000), scaleUp(7000)]);

    await mt.ccReceiveToken(alice.address, bob.address, 3000);
    expect(await rateLimiter.amountCanBeReceived().then(x => correctTime(x)))
      .to.deep.equal([scaleUp(6000), scaleUp(4000)]);

    await expect(mt.ccReceiveToken(alice.address, bob.address, 5000))
      .to.emit(rateLimiter, "RateLimitedMsgAdded")
      .withArgs(0, bob.address, scaleUp(5000), alice.address.toLowerCase());
    expect(await rateLimiter.amountCanBeReceived().then(x => correctTime(x)))
      .to.deep.equal([scaleUp(6000), scaleUp(4000)]);
  });

  it("checkAndUpdateRateLimit: recover", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);

    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(8000), scaleUp(2000)]);

    await time.increase(360); // +1000
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(7000), scaleUp(3000)]);

    await time.increase(720); // +2000
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(5000), scaleUp(5000)]);

    await time.increase(1080); // +3000
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(2000), scaleUp(8000)]);

    await time.increase(1800); // +5000
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(0), scaleUp(10000)]);

    await mt.ccReceiveToken(alice.address, bob.address, 3000);
    expect(await rateLimiter.amountCanBeReceived())
      .to.deep.equal([scaleUp(3000), scaleUp(7000)]);
  });

  it("checkAndUpdateRateLimit: queue", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);

    // check events
    await expect(mt.ccReceiveToken(alice.address, bob.address, 3000))
      .to.emit(rateLimiter, "RateLimitedMsgAdded")
      .withArgs(0, bob.address, scaleUp(3000), alice.address.toLowerCase());
    await expect(mt.ccReceiveToken(bob.address, alice.address, 4000))
      .to.emit(rateLimiter, "RateLimitedMsgAdded")
      .withArgs(1, alice.address, scaleUp(4000), bob.address.toLowerCase());

    // check getters
    expect(await rateLimiter.rateLimitedMsgs(0))
      .to.deep.equal([bob.address, scaleUp(3000), alice.address.toLowerCase()]);
    expect(await rateLimiter.rateLimitedMsgs(1))
      .to.deep.equal([alice.address, scaleUp(4000), bob.address.toLowerCase()]);
    expect(await rateLimiter.rateLimitedMsgsLength())
      .to.equal(2);
  });

  it("checkAndUpdateRateLimit: whitelist", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.updateWhitelist(alice.address, bob.address, true);

    // whitelisted, not consume rate limit
    await expect(mt.ccReceiveToken(alice.address, bob.address, 4000))
      .to.emit(mt, "CCReceiveToken")
      .withArgs(alice.address.toLowerCase(), bob.address, scaleUp(4000));
    expect(await rateLimiter.rateLimitedMsgsLength()).to.equal(0);
    expect(correctTime(await rateLimiter.amountCanBeReceived()))
        .to.deep.equal([scaleUp(0), scaleUp(10000)]);
  });

  it("checkAndUpdateRateLimit: singleMsgLimit", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setSingleMsgLimit(scaleUp(1000));
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.updateWhitelist(alice.address, bob.address, true);

    // test cases
    const testCases = [
      { from: alice, to: bob, amount: 999, emitter: mt, event: "CCReceiveToken", inflight: 0 }, // whitelisted, within limit
      { from: alice, to: bob, amount: 1001, emitter: mt, event: "CCReceiveToken", inflight: 0 }, // whitelisted, exceeds limit
      { from: bob, to: alice, amount: 999, emitter: mt, event: "CCReceiveToken", inflight: 1000 }, // not whitelisted, within limit
      { from: bob, to: alice, amount: 1001, emitter: rateLimiter, event: "RateLimitedMsgAdded", inflight: 1000 }, // not whitelisted, exceeds limit
    ];

    for (const { from, to, amount, emitter, event, inflight } of testCases) {
      await expect(mt.ccReceiveToken(from.address, to.address, amount))
        .to.emit(emitter, event);
      expect(correctTime(await rateLimiter.amountCanBeReceived()))
        .to.deep.equal([scaleUp(inflight), scaleUp(10000 - inflight)]);
    }
  });

  it("removeRateLimitedMsg: NotMToken", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);
    await expect(rateLimiter.connect(alice).removeRateLimitedMsg(123))
      .to.be.revertedWithCustomError(rateLimiter, "NotMToken")
      .withArgs(alice.address);
  });

  it("ccProcessRateLimitedMsg", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0
    await mt.ccReceiveToken(bob.address, alice.address, 4000); // #1

    const tx = mt.connect(operator).ccProcessRateLimitedMsg(1);
    await expect(tx).to.emit(mt, "CCReceiveToken")
      .withArgs(bob.address.toLowerCase(), alice.address, scaleUp(4000));
    await expect(tx).to.emit(mt, "RateLimitedMsgProcessed").withArgs(1);
    await expect(tx).to.emit(rateLimiter, "RateLimitedMsgRemoved").withArgs(1);
    expect(await mt.balanceOf(alice.address)).to.equal(scaleUp(4000));
    expect(await rateLimiter.rateLimitedMsgs(1))
      .to.deep.equal([zeroAddr, 0, "0x"]);

    await expect(mt.connect(operator).ccProcessRateLimitedMsg(1))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(1);
  });

  it("ccDiscardRateLimitedMsg", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000);
    await mt.ccReceiveToken(bob.address, alice.address, 4000);

    const tx = mt.connect(operator).ccDiscardRateLimitedMsg(1);
    await expect(tx).to.emit(mt, "RateLimitedMsgDiscarded").withArgs(1);
    await expect(tx).to.emit(rateLimiter, "RateLimitedMsgRemoved").withArgs(1);
    expect(await mt.balanceOf(alice.address)).to.equal(0);
    expect(await rateLimiter.rateLimitedMsgs(1))
      .to.deep.equal([zeroAddr, 0, "0x"]);

    await expect(mt.connect(operator).ccDiscardRateLimitedMsg(1))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(1);
  });

  it("batch", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0
    await mt.ccReceiveToken(bob.address, alice.address, 4000); // #1
    await mt.ccReceiveToken(bob.address, alice.address, 5000); // #2
    await mt.ccReceiveToken(bob.address, alice.address, 6000); // #3

    await expect(mt.connect(operator).ccBatchProcessRateLimitedMsgs([0, 2]))
      .to.emit(mt, "RateLimitedMsgProcessed").withArgs(0)
      .to.emit(mt, "RateLimitedMsgProcessed").withArgs(2);
    await expect(mt.connect(operator).ccBatchDiscardRateLimitedMsgs([1, 3]))
      .to.emit(mt, "RateLimitedMsgDiscarded").withArgs(1)
      .to.emit(mt, "RateLimitedMsgDiscarded").withArgs(3);
  });

  it("pendingMsgs", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);

    expect(await rateLimiter.pendingMsgCount()).to.equal(0);
    expect(await rateLimiter.hasPendingMsgs()).to.equal(false);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0
    await mt.ccReceiveToken(bob.address, alice.address, 4000); // #1
    expect(await rateLimiter.pendingMsgCount()).to.equal(2);
    expect(await rateLimiter.hasPendingMsgs()).to.equal(true);

    await mt.setRateLimiter(zeroAddr);
    await expect(mt.setRateLimiter(zeroAddr))
      .to.be.revertedWithCustomError(mt, "PendingRateLimitedMsgsExist");
  });

});
