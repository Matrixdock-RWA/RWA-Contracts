const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
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
    expect(await rateLimiter.getRateLimit()).to.deep.equal([0n, 0n]);

    await expect(rateLimiter.connect(alice).setRateLimit(10000, 3600))
      .to.be.revertedWithCustomError(rateLimiter, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);

    // first call: request (rate limit unchanged)
    await expect(rateLimiter.setRateLimit(10000, 3600))
      .to.emit(rateLimiter, "SetRateLimitRequest")
      .withArgs(10000, 3600, anyArg => anyArg > 0n);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([0n, 0n]);

    // second call: execute
    await expect(rateLimiter.setRateLimit(10000, 3600))
      .to.emit(rateLimiter, "SetRateLimitEffected").withArgs(10000, 3600)
      .to.emit(rateLimiter, "RateLimitsChanged").withArgs([[FAKE_DST_EID, 10000, 3600]]);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([10000n, 3600n]);
  });

  it("setRateLimit rejects out-of-range params", async function () {
    const { rateLimiter } = await loadFixture(deployTestFixture);

    // limit overflowing the uint128 half of the packed fingerprint
    await expect(rateLimiter.setRateLimit(2n ** 128n, 3600))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitTooLarge")
      .withArgs(2n ** 128n, 3600);

    // window overflowing the uint32 half of the packed fingerprint
    await expect(rateLimiter.setRateLimit(10000, 2n ** 32n))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitTooLarge")
      .withArgs(10000, 2n ** 32n);

    // max values on both sides are still accepted
    await rateLimiter.setRateLimit(2n ** 128n - 1n, 2n ** 32n - 1n);
    await rateLimiter.setRateLimit(2n ** 128n - 1n, 2n ** 32n - 1n);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([2n ** 128n - 1n, 2n ** 32n - 1n]);
  });

  it("revokeSetRateLimit", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);

    await rateLimiter.setRateLimit(10000, 3600); // request
    expect(await rateLimiter.getRateLimit()).to.deep.equal([0n, 0n]);

    await expect(rateLimiter.connect(alice).revokeSetRateLimit())
      .to.be.revertedWithCustomError(rateLimiter, "NotOwnerOrRevoker");

    await expect(rateLimiter.revokeSetRateLimit())
      .to.emit(rateLimiter, "RequestRevoked");

    // revoke is idempotent: revoking again with no pending request
    // succeeds silently (no event)
    await expect(rateLimiter.revokeSetRateLimit())
      .to.not.emit(rateLimiter, "RequestRevoked");

    // after revoke, can issue a new request with different params
    await rateLimiter.setRateLimit(20000, 7200);
    await rateLimiter.setRateLimit(20000, 7200);
    expect(await rateLimiter.getRateLimit()).to.deep.equal([20000n, 7200n]);
  });

  it("setSingleMsgLimit", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);
    await expect(rateLimiter.connect(alice).setSingleMsgLimit(1000))
      .to.be.revertedWithCustomError(rateLimiter, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);

    // first call: request (limit unchanged)
    await expect(rateLimiter.setSingleMsgLimit(1000))
      .to.emit(rateLimiter, "SetSingleMsgLimitRequest");
    expect(await rateLimiter.singleMsgLimit()).to.equal(0);

    // second call: execute
    await expect(rateLimiter.setSingleMsgLimit(1000))
      .to.emit(rateLimiter, "SetSingleMsgLimitEffected").withArgs(1000);
    expect(await rateLimiter.singleMsgLimit()).to.equal(1000);
  });

  it("setSingleMsgLimit rejects out-of-range param", async function () {
    const { rateLimiter } = await loadFixture(deployTestFixture);

    // limit overflowing the uint160 fingerprint slot
    await expect(rateLimiter.setSingleMsgLimit(2n ** 160n))
      .to.be.revertedWithCustomError(rateLimiter, "SingleMsgLimitTooLarge")
      .withArgs(2n ** 160n);

    // max value is still accepted
    await rateLimiter.setSingleMsgLimit(2n ** 160n - 1n);
    await rateLimiter.setSingleMsgLimit(2n ** 160n - 1n);
    expect(await rateLimiter.singleMsgLimit()).to.equal(2n ** 160n - 1n);
  });

  it("revokeSetSingleMsgLimit", async function () {
    const { rateLimiter, alice } = await loadFixture(deployTestFixture);

    await rateLimiter.setSingleMsgLimit(1000); // request

    await expect(rateLimiter.connect(alice).revokeSetSingleMsgLimit())
      .to.be.revertedWithCustomError(rateLimiter, "NotOwnerOrRevoker");

    await expect(rateLimiter.revokeSetSingleMsgLimit())
      .to.emit(rateLimiter, "RequestRevoked");
    expect(await rateLimiter.singleMsgLimit()).to.equal(0);

    // revoke is idempotent: revoking again with no pending request
    // succeeds silently (no event)
    await expect(rateLimiter.revokeSetSingleMsgLimit())
      .to.not.emit(rateLimiter, "RequestRevoked");

    // after revoke, can issue a new request with different params
    await rateLimiter.setSingleMsgLimit(2000);
    await rateLimiter.setSingleMsgLimit(2000);
    expect(await rateLimiter.singleMsgLimit()).to.equal(2000);
  });

  it("addToWhitelist", async function () {
    const { rateLimiter, alice, bob } = await loadFixture(deployTestFixture);
    const aliceBytes = alice.address.toLowerCase();

    await expect(rateLimiter.connect(alice).addToWhitelist(aliceBytes, bob.address))
      .to.be.revertedWithCustomError(rateLimiter, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);

    // first call: request (whitelist unchanged)
    await expect(rateLimiter.addToWhitelist(aliceBytes, bob.address))
      .to.emit(rateLimiter, "AddToWhitelistRequest");
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(false);

    // second call: execute
    await expect(rateLimiter.addToWhitelist(aliceBytes, bob.address))
      .to.emit(rateLimiter, "AddToWhitelistEffected")
      .withArgs(aliceBytes, bob.address);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(true);
  });

  it("removeFromWhitelist", async function () {
    const { rateLimiter, alice, bob } = await loadFixture(deployTestFixture);
    const aliceBytes = alice.address.toLowerCase();

    // add first
    await rateLimiter.addToWhitelist(aliceBytes, bob.address);
    await rateLimiter.addToWhitelist(aliceBytes, bob.address);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(true);

    await expect(rateLimiter.connect(alice).removeFromWhitelist(aliceBytes, bob.address))
      .to.be.revertedWithCustomError(rateLimiter, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);

    // immediate removal, no second call needed
    await expect(rateLimiter.removeFromWhitelist(aliceBytes, bob.address))
      .to.emit(rateLimiter, "RemovedFromWhitelist")
      .withArgs(aliceBytes, bob.address);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(false);
  });

  it("revokeAddToWhitelist", async function () {
    const { rateLimiter, alice, bob } = await loadFixture(deployTestFixture);
    const aliceBytes = alice.address.toLowerCase();

    await rateLimiter.addToWhitelist(aliceBytes, bob.address); // request

    await expect(rateLimiter.connect(alice).revokeAddToWhitelist(aliceBytes, bob.address))
      .to.be.revertedWithCustomError(rateLimiter, "NotOwnerOrRevoker");

    await expect(rateLimiter.revokeAddToWhitelist(aliceBytes, bob.address))
      .to.emit(rateLimiter, "RequestRevoked");
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(false);

    // revoke is idempotent: revoking again with no pending request
    // succeeds silently (no event)
    await expect(rateLimiter.revokeAddToWhitelist(aliceBytes, bob.address))
      .to.not.emit(rateLimiter, "RequestRevoked");

    // after revoke, can issue a new request
    await rateLimiter.addToWhitelist(aliceBytes, bob.address);
    await rateLimiter.addToWhitelist(aliceBytes, bob.address);
    expect(await rateLimiter.isInWhitelist(aliceBytes, bob.address)).to.equal(true);
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
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.addToWhitelist(alice.address, bob.address);
    await rateLimiter.addToWhitelist(alice.address, bob.address);

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
    await rateLimiter.setSingleMsgLimit(scaleUp(1000));
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.addToWhitelist(alice.address, bob.address);
    await rateLimiter.addToWhitelist(alice.address, bob.address);

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
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0
    await mt.ccReceiveToken(bob.address, alice.address, 4000); // #1

    // ccProcessRateLimitedMsg is delayed (delay=0: two calls)
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(1))
      .to.emit(mt, "RateLimitedMsgProcessRequest").withArgs(1, anyValue);
    const tx = mt.connect(operator).ccProcessRateLimitedMsg(1);
    await expect(tx).to.emit(mt, "CCReceiveToken")
      .withArgs(bob.address.toLowerCase(), alice.address, scaleUp(4000));
    await expect(tx).to.emit(mt, "RateLimitedMsgProcessEffected").withArgs(1);
    await expect(tx).to.emit(rateLimiter, "RateLimitedMsgRemoved").withArgs(1);
    expect(await mt.balanceOf(alice.address)).to.equal(scaleUp(4000));
    expect(await rateLimiter.rateLimitedMsgs(1))
      .to.deep.equal([zeroAddr, 0, "0x"]);

    // index 1 is now a dead slot: even a fresh request is rejected immediately,
    // rather than only failing later when it matures
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(1))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(1);

    // paused: processing is blocked (request phase is also guarded by whenNotPaused)
    await mt.connect(operator).pause();
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.be.revertedWithCustomError(mt, "GlobalPaused");

    // unpause (delay=0: two calls) and processing resumes
    await mt.unpause();
    await mt.unpause();
    await mt.connect(operator).ccProcessRateLimitedMsg(0);
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.emit(mt, "RateLimitedMsgProcessEffected").withArgs(0);
  });

  it("ccDiscardRateLimitedMsg", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000);
    await mt.ccReceiveToken(bob.address, alice.address, 4000);

    // discard has no whenNotPaused by design: malicious queued messages
    // must be removable even while the token is paused
    await mt.connect(operator).pause();

    // ccDiscardRateLimitedMsg is delayed (delay=0: two calls)
    await expect(mt.connect(operator).ccDiscardRateLimitedMsg(1))
      .to.emit(mt, "RateLimitedMsgDiscardRequest").withArgs(1, anyValue);
    const tx = mt.connect(operator).ccDiscardRateLimitedMsg(1);
    await expect(tx).to.emit(mt, "RateLimitedMsgDiscardEffected").withArgs(1);
    await expect(tx).to.emit(rateLimiter, "RateLimitedMsgRemoved").withArgs(1);
    expect(await mt.balanceOf(alice.address)).to.equal(0);
    expect(await rateLimiter.rateLimitedMsgs(1))
      .to.deep.equal([zeroAddr, 0, "0x"]);

    // index 1 is now a dead slot: even a fresh request is rejected immediately,
    // rather than only failing later when it matures
    await expect(mt.connect(operator).ccDiscardRateLimitedMsg(1))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(1);
  });

  it("ccProcessRateLimitedMsg cannot pre-plant a request for a not-yet-queued message", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);

    // no message has ever been queued: index 0 is out of bounds in the rate
    // limiter's array, so the peek itself reverts
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(0);
    await expect(mt.connect(operator).ccDiscardRateLimitedMsg(0))
      .to.be.revertedWithCustomError(rateLimiter, "RateLimitedMsgInvalid")
      .withArgs(0);

    // once #0 actually exists, requesting against it works normally
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.emit(mt, "RateLimitedMsgProcessRequest").withArgs(0, anyValue);
  });

  it("a request tied to a since-replaced rate limiter cannot be matured against a new one", async function () {
    const { mt, rateLimiter, operator, alice, bob, owner } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(alice.address, bob.address, 3000); // #0 in the old rate limiter

    // pre-register a process request against the old rate limiter's #0, but
    // never mature/execute it
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.emit(mt, "RateLimitedMsgProcessRequest").withArgs(0, anyValue);

    // drain the old rate limiter so it can be swapped out
    await mt.connect(operator).ccDiscardRateLimitedMsg(0);
    await mt.connect(operator).ccDiscardRateLimitedMsg(0);

    // swap in a brand-new rate limiter
    const MTokenRateLimiter = await ethers.getContractFactory("MTokenRateLimiter");
    const rateLimiter2 = await upgrades.deployProxy(MTokenRateLimiter,
      [owner.address, owner.address, owner.address, 0, 0],
      {
        kind: "uups",
        constructorArgs: [mt.target],
        unsafeAllow: ['constructor', 'state-variable-immutable'],
      }
    );
    await mt.setRateLimiter(rateLimiter2.target);
    await mt.setRateLimiter(rateLimiter2.target);
    await mt.setMessenger(operator.address); // ccReceiveToken helper below re-sends through mt
    await mt.setMessenger(operator.address);

    // a different, unrelated message lands at #0 in the new rate limiter
    await rateLimiter2.setRateLimit(scaleUp(10000), 3600);
    await rateLimiter2.setRateLimit(scaleUp(10000), 3600);
    await mt.ccReceiveToken(alice.address, bob.address, 8000);
    await mt.ccReceiveToken(bob.address, alice.address, 5000); // #0 in the new rate limiter

    // the stale request from the old rate limiter must NOT mature this
    // unrelated message instantly; it should register as a brand-new request
    await expect(mt.connect(operator).ccProcessRateLimitedMsg(0))
      .to.emit(mt, "RateLimitedMsgProcessRequest").withArgs(0, anyValue);
    expect(await rateLimiter2.rateLimitedMsgs(0))
      .to.deep.equal([alice.address, scaleUp(5000), bob.address.toLowerCase()]);
  });

  it("pendingMsgs", async function () {
    const { mt, rateLimiter, operator, alice, bob } = await loadFixture(deployTestFixture);
    await setupRateLimiter(mt, rateLimiter, operator);
    await rateLimiter.setRateLimit(scaleUp(10000), 3600);
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
