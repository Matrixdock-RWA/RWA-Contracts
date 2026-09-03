const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {
  deployTestFixture, getTS,
  zeroAddr,
} = require("./MTokenTestUtils.js");

const HOUR = 3600;
const DAY = 24 * 3600;
const WEEK = 7 * 24 * 3600;

const OP = {
  govDelay: ethers.keccak256(ethers.toUtf8Bytes("OP_SET_GOV_DELAY")),
  delay:    ethers.keccak256(ethers.toUtf8Bytes("OP_SET_DELAY")),
  operator: ethers.keccak256(ethers.toUtf8Bytes("OP_SET_OPERATOR")),
  revoker:  ethers.keccak256(ethers.toUtf8Bytes("OP_SET_REVOKER")),
};

// Shared behavior tests for the delayed role/param updates (govDelay, delay,
// operator, revoker, ownership) implemented by:
//   - mt / mtSide — MToken (unified revokeRequest; setDelay gated by govDelay)
//   - rateLimiter — DelayedRolesUpgradeable (per-op revokeNext*; setDelay
//     gated by delay itself)
//
// Access-control differences between the implementations:
//                        | MToken            | DelayedRolesUpgradeable
//   revoke delay/operator| owner or revoker  | revoker only
//   revoke revoker       | owner or operator | owner only
//   revoke govDelay/owner| owner or revoker  | owner only
describe("MTokenRoles", function () {

  for (const cName of ["mt", "mtSide", "rateLimiter"]) {
    const isMToken = cName == "mt" || cName == "mtSide";

    const revokeDelayReq    = (c, s) => isMToken ? c.connect(s).revokeRequest(OP.delay)    : c.connect(s).revokeNextDelay();
    const revokeOperatorReq = (c, s) => isMToken ? c.connect(s).revokeRequest(OP.operator) : c.connect(s).revokeNextOperator();
    const revokeRevokerErr  = isMToken ? "NotOwnerOrOperator" : "OwnableUnauthorizedAccount";
    const ownerOrRevokerErr = isMToken ? "NotOwnerOrRevoker"  : "OwnableUnauthorizedAccount";

    const expectNotRevoker = (p, c, addr) =>
      expect(p).to.be.revertedWithCustomError(c, isMToken ? "NotOwnerOrRevoker" : "NotRevoker").withArgs(addr);

    describe("contract: " + cName, function () {

      it("setGovDelay", async function () {
        const fixture = await loadFixture(deployTestFixture);
        const {alice} = fixture;
        const _c = fixture[cName];

        expect(await _c.getGovDelay()).to.equal(0);

        // only owner
        await expect(_c.connect(alice).setGovDelay(DAY))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        // bounds: MIN_GOV_DELAY (1d) / MAX_GOV_DELAY (7d)
        await expect(_c.setGovDelay(DAY - 1))
          .to.be.revertedWithCustomError(_c, "DelayTooSmall");
        await expect(_c.setGovDelay(WEEK + 1))
          .to.be.revertedWithCustomError(_c, "DelayTooLarge");

        // govDelay=0: first call requests, second call executes
        await expect(_c.setGovDelay(DAY))
          .to.emit(_c, "DelayedOpRequest").withArgs(OP.govDelay, 0, DAY, anyValue);
        expect(await _c.getGovDelay()).to.equal(0);
        await expect(_c.setGovDelay(DAY))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.govDelay, DAY);
        expect(await _c.getGovDelay()).to.equal(DAY);

        // now time-locked: second call while pending reverts
        const tx1 = await _c.setGovDelay(2 * DAY);
        const ts1 = await getTS(tx1);
        expect((await _c.requestMap(OP.govDelay)).effectiveTime).to.equal(BigInt(ts1 + DAY));
        await expect(_c.setGovDelay(2 * DAY))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute")
          .withArgs(OP.govDelay);

        // revoke: unauthorized, then owner
        await expect(_c.connect(alice).revokeNextGovDelay())
          .to.be.revertedWithCustomError(_c, ownerOrRevokerErr)
          .withArgs(alice.address);
        await _c.revokeNextGovDelay();
        expect((await _c.requestMap(OP.govDelay)).effectiveTime).to.equal(0n);

        // re-request and execute after the delay
        await _c.setGovDelay(2 * DAY);
        await time.increase(DAY + 1);
        await expect(_c.setGovDelay(2 * DAY))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.govDelay, 2 * DAY);
        expect(await _c.getGovDelay()).to.equal(2 * DAY);

        // exactly MAX_GOV_DELAY (7d) is allowed
        await _c.setGovDelay(WEEK);
        await time.increase(2 * DAY + 1);
        await expect(_c.setGovDelay(WEEK))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.govDelay, WEEK);
        expect(await _c.getGovDelay()).to.equal(WEEK);

        // make the operational delay nonzero (1h) so a govDelay/delay mix-up
        // in the time-lock arithmetic below cannot cancel out
        await _c.setDelay(HOUR);
        if (isMToken) {
          await time.increase(WEEK + 1); // mt gates setDelay by govDelay
        }
        await _c.setDelay(HOUR);
        expect(await _c.delay()).to.equal(HOUR);

        // lowering govDelay must wait out the CURRENT (old, longer) govDelay:
        // neither the operational delay (1h) nor the new value (2d) opens the lock
        const tx2 = await _c.setGovDelay(2 * DAY);
        const ts2 = await getTS(tx2);
        await expect(tx2).to.emit(_c, "DelayedOpRequest").withArgs(OP.govDelay, WEEK, 2 * DAY, ts2 + WEEK);
        expect((await _c.requestMap(OP.govDelay)).effectiveTime).to.equal(BigInt(ts2 + WEEK));

        await time.increase(HOUR + 1); // past the operational delay
        await expect(_c.setGovDelay(2 * DAY))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute").withArgs(OP.govDelay);
        await time.increase(2 * DAY); // past the new govDelay value
        await expect(_c.setGovDelay(2 * DAY))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute").withArgs(OP.govDelay);
        await time.increase(WEEK); // past the old govDelay
        await expect(_c.setGovDelay(2 * DAY))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.govDelay, 2 * DAY);
        expect(await _c.getGovDelay()).to.equal(2 * DAY);
      });

      it("setDelay", async function () {
        const fixture = await loadFixture(deployTestFixture);
        const {alice} = fixture;
        const _c = fixture[cName];

        expect(await _c.delay()).to.equal(0);

        // only owner
        await expect(_c.connect(alice).setDelay(HOUR))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        // bounds: MIN_DELAY (1h) / MAX_DELAY (48h)
        await expect(_c.setDelay(HOUR - 1))
          .to.be.revertedWithCustomError(_c, "DelayTooSmall");
        await expect(_c.setDelay(48 * HOUR + 1))
          .to.be.revertedWithCustomError(_c, "DelayTooLarge");

        // cross-check: delay may not exceed govDelay (still 0)
        await expect(_c.setDelay(HOUR))
          .to.be.revertedWithCustomError(_c, "DelayTooLarge");

        // raise govDelay first (it is also the gate of MToken's setDelay)
        await _c.setGovDelay(DAY);
        await _c.setGovDelay(DAY);

        // delay=0: two calls execute (mt waits out govDelay in between)
        const gate = isMToken ? DAY : HOUR;
        await expect(_c.setDelay(HOUR))
          .to.emit(_c, "DelayedOpRequest").withArgs(OP.delay, 0, HOUR, anyValue);
        expect(await _c.delay()).to.equal(0);
        if (isMToken) {
          await time.increase(DAY + 1);
        }
        await expect(_c.setDelay(HOUR))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.delay, HOUR);
        expect(await _c.delay()).to.equal(HOUR);

        // now time-locked: request, value not yet applied
        const tx1 = await _c.setDelay(2 * HOUR);
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(_c, "DelayedOpRequest").withArgs(OP.delay, HOUR, 2 * HOUR, anyValue);
        expect(await _c.delay()).to.equal(HOUR);
        expect((await _c.requestMap(OP.delay)).effectiveTime).to.equal(BigInt(ts1 + gate));

        // second call while pending: TooEarlyToExecute
        await expect(_c.setDelay(2 * HOUR))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute")
          .withArgs(OP.delay);

        // revoke: unauthorized, then authorized
        // (mt: owner via revokeRequest; rateLimiter: owner is also the revoker)
        await expectNotRevoker(revokeDelayReq(_c, alice), _c, alice.address);
        await revokeDelayReq(_c, fixture.owner);
        expect((await _c.requestMap(OP.delay)).effectiveTime).to.equal(0n);

        // re-request and execute after the delay
        await _c.setDelay(2 * HOUR);
        await time.increase(gate + 1);
        await expect(_c.setDelay(2 * HOUR))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.delay, 2 * HOUR);
        expect(await _c.delay()).to.equal(2 * HOUR);

        // isolate the MAX_DELAY branch: with govDelay at 3d the govDelay
        // cross-check can't fire, yet 48h+1 must still be rejected
        await _c.setGovDelay(3 * DAY);
        await time.increase(DAY + 1);
        await _c.setGovDelay(3 * DAY);
        await expect(_c.setDelay(48 * HOUR + 1))
          .to.be.revertedWithCustomError(_c, "DelayTooLarge");

        // raise delay to exactly MAX_DELAY (48h)
        await _c.setDelay(48 * HOUR);
        await time.increase(3 * DAY + 1);
        await _c.setDelay(48 * HOUR);
        expect(await _c.delay()).to.equal(48 * HOUR);

        // cross-check: govDelay may not drop below delay...
        await expect(_c.setGovDelay(DAY))
          .to.be.revertedWithCustomError(_c, "DelayTooSmall");

        // ...but dropping it to exactly delay (48h) is allowed
        await _c.setGovDelay(2 * DAY);
        await time.increase(3 * DAY + 1);
        await _c.setGovDelay(2 * DAY);
        expect(await _c.getGovDelay()).to.equal(2 * DAY);
      });

      it("setOperator", async function () {
        const fixture = await loadFixture(deployTestFixture);
        const {owner, operator, alice, bob} = fixture;
        const _c = fixture[cName];

        const initOperator = cName == "rateLimiter" ? owner.address : operator.address;
        expect(await _c.operator()).to.equal(initOperator);

        // only owner; zero address rejected
        await expect(_c.connect(alice).setOperator(bob.address))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);
        await expect(_c.setOperator(zeroAddr))
          .to.be.revertedWithCustomError(_c, "ZeroAddress");

        // delay=0: first call requests, second call executes
        await expect(_c.setOperator(bob.address))
          .to.emit(_c, "DelayedOpRequest").withArgs(OP.operator, BigInt(initOperator), BigInt(bob.address), anyValue);
        expect(await _c.operator()).to.equal(initOperator);
        await expect(_c.setOperator(bob.address))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.operator, BigInt(bob.address));
        expect(await _c.operator()).to.equal(bob.address);

        // activate the time-lock (operator changes are gated by delay;
        // govDelay must be raised first — delay can't exceed it)
        await _c.setGovDelay(DAY);
        await _c.setGovDelay(DAY);
        await _c.setDelay(HOUR);
        if (isMToken) {
          await time.increase(DAY + 1);
        }
        await _c.setDelay(HOUR);

        // now time-locked: request, value not yet applied
        const tx1 = await _c.setOperator(alice.address);
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(_c, "DelayedOpRequest").withArgs(OP.operator, BigInt(bob.address), BigInt(alice.address), anyValue);
        expect(await _c.operator()).to.equal(bob.address);
        expect((await _c.requestMap(OP.operator)).effectiveTime).to.equal(BigInt(ts1 + HOUR));

        // second call while pending: TooEarlyToExecute
        await expect(_c.setOperator(alice.address))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute")
          .withArgs(OP.operator);

        // revoke: unauthorized, then authorized
        await expectNotRevoker(revokeOperatorReq(_c, alice), _c, alice.address);
        await revokeOperatorReq(_c, owner);
        expect((await _c.requestMap(OP.operator)).effectiveTime).to.equal(0n);

        // re-request and execute after the delay
        await _c.setOperator(alice.address);
        await time.increase(HOUR + 1);
        await expect(_c.setOperator(alice.address))
          .to.emit(_c, "DelayedOpEffected").withArgs(OP.operator, BigInt(alice.address));
        expect(await _c.operator()).to.equal(alice.address);
      });

      // setRevoker is two-step: the owner queues the change, and after govDelay
      // the new revoker itself calls acceptRevoker to bring it into effect.
      it("setRevoker", async function () {
        const fixture = await loadFixture(deployTestFixture);
        const {owner, operator, alice, bob} = fixture;
        const _c = fixture[cName];
        const getEt = async () => (await _c.requestMap(OP.revoker)).effectiveTime;

        const initRevoker = cName == "rateLimiter" ? owner.address : zeroAddr;
        expect(await _c.revoker()).to.equal(initRevoker);

        // revoker changes are gated by govDelay (govDelay=0: two calls needed)
        await _c.setGovDelay(DAY);
        await _c.setGovDelay(DAY);

        // accept without a pending request: NoPendingRequest
        await expect(_c.connect(bob).acceptRevoker())
          .to.be.revertedWithCustomError(_c, "NoPendingRequest")
          .withArgs(OP.revoker);

        // request: only owner; zero address rejected
        await expect(_c.connect(alice).setRevoker(bob.address))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);
        await expect(_c.setRevoker(zeroAddr))
          .to.be.revertedWithCustomError(_c, "ZeroAddress");

        // request: ok, emits Request event, value not yet applied
        const tx1 = await _c.setRevoker(bob.address);
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(_c, "DelayedOpRequest").withArgs(OP.revoker, BigInt(initRevoker), BigInt(bob.address), anyValue);
        expect(await _c.revoker()).to.equal(initRevoker);
        expect(await getEt()).to.equal(BigInt(ts1 + DAY));

        // request again / accept while pending: TooEarlyToExecute
        await expect(_c.setRevoker(bob.address))
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute")
          .withArgs(OP.revoker);
        await expect(_c.connect(bob).acceptRevoker())
          .to.be.revertedWithCustomError(_c, "TooEarlyToExecute")
          .withArgs(OP.revoker);

        await time.increase(DAY + 1);

        // even after the delay, the owner can't apply the change directly
        await expect(_c.setRevoker(bob.address))
          .to.be.revertedWithCustomError(_c, "NotNewRevoker")
          .withArgs(owner.address);

        // only the pending revoker can accept
        await expect(_c.connect(alice).acceptRevoker())
          .to.be.revertedWithCustomError(_c, "RequestArgsMismatch")
          .withArgs(OP.revoker);

        // accept: takes effect, entry deleted after execution
        await expect(_c.connect(bob).acceptRevoker())
          .to.emit(_c, "DelayedOpEffected")
          .withArgs(OP.revoker, BigInt(bob.address));
        expect(await _c.revoker()).to.equal(bob.address);
        expect(await getEt()).to.equal(0n);

        // revoke a pending request: unauthorized (the revoker itself can't), then owner
        await _c.setRevoker(alice.address);
        await expect(_c.connect(bob).revokeNextRevoker())
          .to.be.revertedWithCustomError(_c, revokeRevokerErr)
          .withArgs(bob.address);
        await _c.revokeNextRevoker();
        expect(await getEt()).to.equal(0n);

        // mt: the operator can also revoke (onlyOwnerOrOperator)
        if (isMToken) {
          await _c.setRevoker(alice.address);
          await _c.connect(operator).revokeNextRevoker();
          expect(await getEt()).to.equal(0n);
        }
      });

      it("transferOwnership", async function() {
        const fixture = await loadFixture(deployTestFixture);
        const {owner, alice, bob} = fixture;
        const _c = fixture[cName];

        expect(await _c.owner()).to.equal(owner.address);
        expect(await _c.pendingOwner()).to.equal(zeroAddr);

        // renounceOwnership is disabled
        await expect(_c.renounceOwnership())
          .to.be.revertedWithCustomError(_c, "NotSupport");

        // only owner
        await expect(_c.connect(alice).transferOwnership(bob.address))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        // ownership transfers are gated by govDelay (govDelay=0: two calls needed)
        await _c.setGovDelay(DAY);
        await _c.setGovDelay(DAY);

        // request: pending owner set, owner unchanged
        const tx1 = await _c.transferOwnership(bob.address);
        const ts1 = await getTS(tx1);
        await expect(tx1).to.emit(_c, "OwnershipTransferStarted")
          .withArgs(owner.address, bob.address, ts1 + DAY);
        expect(await _c.pendingOwner()).to.equal(bob.address);
        expect(await _c.owner()).to.equal(owner.address);

        // second transfer while one is pending: PendingOwnerExist
        await expect(_c.transferOwnership(alice.address))
          .to.be.revertedWithCustomError(_c, "PendingOwnerExist")
          .withArgs(bob.address);

        // only the pending owner can accept, and not before the delay
        await expect(_c.connect(alice).acceptOwnership())
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);
        await expect(_c.connect(bob).acceptOwnership())
          .to.be.revertedWithCustomError(_c, "TooEarlyToAcceptOwnership")
          .withArgs(ts1 + DAY);

        // revoke the pending transfer: unauthorized, then owner
        await expect(_c.connect(alice).revokeOwnershipTransfer())
          .to.be.revertedWithCustomError(_c, ownerOrRevokerErr)
          .withArgs(alice.address);
        await expect(_c.revokeOwnershipTransfer())
          .to.emit(_c, "OwnershipTransferRevoked")
          .withArgs(bob.address);
        expect(await _c.pendingOwner()).to.equal(zeroAddr);

        // after revoke, the old pending owner can't accept anymore
        await expect(_c.connect(bob).acceptOwnership())
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(bob.address);

        // re-request and accept after the delay
        await _c.transferOwnership(bob.address);
        await time.increase(DAY + 1);
        await expect(_c.connect(bob).acceptOwnership())
          .to.emit(_c, "OwnershipTransferred")
          .withArgs(owner.address, bob.address);
        expect(await _c.owner()).to.equal(bob.address);
        expect(await _c.pendingOwner()).to.equal(zeroAddr);

        // the old owner lost its privileges
        await expect(_c.transferOwnership(alice.address))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(owner.address);
      });

    });

  }

});
