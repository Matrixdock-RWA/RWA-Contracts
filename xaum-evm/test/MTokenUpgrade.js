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

  for (const cName of ["mt", "mtSide", "nft", "mtMsg", "mtMsgSide"]) {
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
        if (cName.startsWith("mtMsg")) {
          await _c.setDelay(100000);
          await _c.setDelay(100000);
        }

        await expect(_c.connect(alice).requestUpgradeToAndCall(bob.address, "0xb0b0"))
          .to.be.revertedWithCustomError(_c, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);

        const revokeErr = cName.startsWith("mtMsg") ? "OwnableUnauthorizedAccount" : "NotRevoker";
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
          await _mt.setRevoker(bob.address);
          await _mt.setDelay(100000);
          await _mt.setDelay(100000);
        }

        if (cName.startsWith("mtMsg")) {
          await _c.setDelay(100000);
          await _c.setDelay(100000);
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

        const revoker = cName.startsWith("mtMsg") ? owner : bob;
        await _c.connect(revoker).revokeNextUpgrade();
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

});