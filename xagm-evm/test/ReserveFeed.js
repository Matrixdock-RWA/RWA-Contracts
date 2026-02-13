const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");

async function getTS(tx) {
  const block = await ethers.provider.getBlock(tx.blockNumber);
  return block.timestamp;
}

describe("FallbackReserveFeed", function () {

  async function deployFeedFixture() {
    const [owner, alice, bob] = await ethers.getSigners();

    const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
    const reserveFeed = await FallbackReserveFeed.deploy(owner.address);

    return {reserveFeed, owner, alice, bob};
  };

  it("init", async function () {
      const { reserveFeed, owner } = await loadFixture(deployFeedFixture);

      expect(await reserveFeed.owner()).to.equal(owner.address);
      expect(await reserveFeed.decimals()).to.equal(9);
      expect(await reserveFeed.description()).to.equal("MatrixDock Silver (XAGm) Reserve");
      expect(await reserveFeed.version()).to.equal(1);

      expect(await reserveFeed.roundId()).to.equal(0);
      expect(await reserveFeed.reserve()).to.equal(0);
      expect(await reserveFeed.updatedAt()).to.equal(0);
  });

  it("setReserve", async function () {
    const { reserveFeed, alice } = await loadFixture(deployFeedFixture);

    await expect(reserveFeed.connect(alice).setReserve(123))
      .to.be.revertedWithCustomError(reserveFeed, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);

    await expect(reserveFeed.setReserve(10000))
      .to.emit(reserveFeed, "ReserveSet")
      .withArgs(1, 10000);
    expect(await reserveFeed.roundId()).to.equal(1);
    expect(await reserveFeed.reserve()).to.equal(10000);

    const tx = await reserveFeed.setReserve(20000);
    const ts = await getTS(tx);
    expect(await reserveFeed.roundId()).to.equal(2);
    expect(await reserveFeed.reserve()).to.equal(20000);
    expect(await reserveFeed.updatedAt()).to.equal(ts);
    expect(await reserveFeed.latestRoundData())
      .to.deep.equal([2, 20000, ts, ts, 2]);
    expect(await reserveFeed.getRoundData(2))
      .to.deep.equal([2, 20000, ts, ts, 2]);

    await expect(reserveFeed.getRoundData(3))
      .to.be.revertedWith("NO_DATA");
  });

});
