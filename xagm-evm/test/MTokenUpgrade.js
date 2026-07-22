const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const {
  deployTestFixture, getTS,
  zeroAddr,
} = require("./MTokenTestUtils.js");

describe("MTokenUpgrade", function () {

  for (const cName of ["mt", "mtSide", "mtMsg", "mtMsgSide"]) {
    describe("upgrade: " + cName, function () {

      it("request/revoke", async function() {
        const fixture = await loadFixture(deployTestFixture);
        const {mt, mtSide, owner, alice, bob} = fixture;
        const _c = fixture[cName];
        for (const _mt of [mt, mtSide]) {
          await _mt.setRevoker(bob.address);
          await _mt.connect(bob).acceptRevoker();
        }
        await _c.setGovDelay(100000);
        await _c.setGovDelay(100000);
        if (cName.startsWith("mtMsg")) {
          await _c.setDelay(100000);
          await _c.setDelay(100000);
        }

        await expect(_c.connect(alice).requestUpgradeToAndCall(bob.address, "0xb0b0"))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        const revokeErr = cName.startsWith("mtMsg") ? "OwnableUnauthorizedAccount" : "NotOwnerOrRevoker";
        await expect(_c.connect(alice).revokeNextUpgrade())
          .to.be.revertedWithCustomError(_c, revokeErr)
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

        const revoker = cName.startsWith("mtMsg") ? owner : bob;
        await _c.connect(revoker).revokeNextUpgrade();
        expect(await _c.etNextUpgradeToAndCall()).to.equal(0);
      });

      it("upgradeToAndCall", async function() {
        const fixture = await loadFixture(deployTestFixture);
        const {mt, mtSide, owner, alice, bob} = fixture;
        const _c = fixture[cName];
        for (const _mt of [mt, mtSide]) {
          await _mt.setRevoker(bob.address);
          await _mt.connect(bob).acceptRevoker();
        }
        await _c.setGovDelay(100000);
        await _c.setGovDelay(100000);
        if (cName.startsWith("mtMsg")) {
          await _c.setDelay(100000);
          await _c.setDelay(100000);
        }

        const MTokenMain2 = await ethers.getContractFactory("MTokenMain2");
        const impl2 = await MTokenMain2.deploy();
        await _c.connect(owner).requestUpgradeToAndCall(impl2.target, "0x");

        await expect(_c.connect(owner).upgradeToAndCall(bob.address, "0x"))
          .to.be.revertedWithCustomError(_c, "InvalidUpgradeToAndCallImpl");
        await expect(_c.connect(owner).upgradeToAndCall(impl2.target, "0x1234"))
          .to.be.revertedWithCustomError(_c, "InvalidUpgradeToAndCallData");
        await expect(_c.connect(owner).upgradeToAndCall(impl2.target, "0x"))
          .to.be.revertedWithCustomError(_c, "TooEarlyToUpgradeToAndCall");

        await time.increase(100000);
        await expect(_c.connect(alice).upgradeToAndCall(impl2.target, "0x"))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        const revoker = cName.startsWith("mtMsg") ? owner : bob;
        await _c.connect(revoker).revokeNextUpgrade();
        expect(await _c.etNextUpgradeToAndCall()).to.equal(0);
        await expect(_c.connect(owner).upgradeToAndCall(impl2.target, "0x"))
          .to.be.revertedWithCustomError(_c, "TooEarlyToUpgradeToAndCall");

        // zeroAddr
        await expect(_c.connect(owner).requestUpgradeToAndCall(zeroAddr, "0x"))
          .to.be.revertedWithCustomError(_c, "ZeroAddress");

        // ok
        await _c.connect(owner).requestUpgradeToAndCall(impl2.target, "0x");
        await time.increase(100000);
        await _c.connect(owner).upgradeToAndCall(impl2.target, "0x");
        expect(await upgrades.erc1967.getImplementationAddress(_c.target))
          .to.equal(impl2.target);
        expect(await MTokenMain2.attach(_c.target).version()).to.equal(2);

        // the authorization is consumed: same request cannot be executed twice
        expect(await _c.nextImplementation()).to.equal(zeroAddr);
        expect(await _c.nextUpgradeToAndCallDataHash()).to.equal(ethers.ZeroHash);
        expect(await _c.etNextUpgradeToAndCall()).to.equal(0);
        await expect(_c.connect(owner).upgradeToAndCall(impl2.target, "0x"))
          .to.be.revertedWithCustomError(_c, "InvalidUpgradeToAndCallImpl");
      });

    });
  }

});
