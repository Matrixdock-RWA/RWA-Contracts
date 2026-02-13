const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {
  zeroAddr
} = require("./MTokenTestUtils.js");

const SECONDS_PER_DAY = 24 * 60 * 60;
const DEFAULT_FEE_RATE_ANNUAL = 0.0025e9; // 0.25%
const DEFAULT_OZ_PER_TOKEN_BASE = 1.0e9; // 1.0

const currDayStartTS = Math.floor((Date.now() / 1000 / SECONDS_PER_DAY)) * SECONDS_PER_DAY;


describe("MToken2", function () {

  async function deployTestFixture() {
    const [owner, operator, feeCollector, alice, bob] = await ethers.getSigners();
  
    const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
    const reserveFeed = await FallbackReserveFeed.deploy(owner.address);
    await reserveFeed.setReserve(100000000);
  
    const MTokenMain = await ethers.getContractFactory("MTokenMain");
    const mt = await upgrades.deployProxy(MTokenMain, 
      [
        "MTokenMain", "MTM", owner.address, operator.address, reserveFeed.target, 
        DEFAULT_FEE_RATE_ANNUAL,
        DEFAULT_OZ_PER_TOKEN_BASE,
        feeCollector.address,
      ],
      {kind: "uups"}
    );

    mt.ozPerTokenStr = async function () {
      return ethers.formatUnits(await this.ozPerToken(), 9);
    };

    return {
      reserveFeed, mt,
      owner, operator, feeCollector, alice, bob, 
    };
  }

  it("__MTOKEN_init_unchained: errors", async function () {
    const [owner, operator, reserveFeed] = await ethers.getSigners();
    const MTokenMain = await ethers.getContractFactory("MTokenMain");

    const testCases = [
      {
        annualFeeRate: 0.11e9,
        ozPerTokenBase: 1.0e9,
        customError: "AnnualFeeRateTooLarge",
      },
      {
        annualFeeRate: 0.003e9,
        ozPerTokenBase: 1.01e9,
        customError: "OzPerTokenBaseTooLarge",
      },
    ];

    for (const {annualFeeRate, ozPerTokenBase, customError} of testCases) {
      await expect(upgrades.deployProxy(
        MTokenMain,
        [
          "MTokenMain", "MTM", owner.address, operator.address, reserveFeed.address, 
          annualFeeRate, ozPerTokenBase, 
          owner.address,
        ],
        {kind: "uups"}
      )).to.be.revertedWithCustomError(MTokenMain, customError);
    }
  });

  it("init", async function () {
    const {mt, feeCollector} = await loadFixture(deployTestFixture);
    expect(await mt.lastReconcileTime()).to.equal(currDayStartTS);
    expect(await mt.ozPerTokenBaseTime()).to.equal(currDayStartTS);
    expect(await mt.annualFeeRate()).to.equal(DEFAULT_FEE_RATE_ANNUAL);
    expect(await mt.ozPerTokenBase()).to.equal(DEFAULT_OZ_PER_TOKEN_BASE);
    expect(await mt.feeCollector()).to.equal(feeCollector.address);
  });

  it("ozPerToken", async function () {
    const {mt} = await loadFixture(deployTestFixture);
    
    let ozPerTokenBase = 1000000000n;
    expect(await mt.annualFeeRate()).to.equal(0.0025e9); // 0.25%
    for (let i = 1n; i <= 10n; i++) {
      await time.increase(24 * 3600); // 1d
      expect(await mt.ozPerToken()).to.equal(ozPerTokenBase - 2500000n * i / 365n);
    }

    await mt.updateAnnualFeeRate(0.005e9); // 0.5%
    ozPerTokenBase = await mt.ozPerToken();
    expect(await mt.annualFeeRate()).to.equal(0.005e9);
    expect(ozPerTokenBase).to.equal(1000000000n - 2500000n * 10n / 365n);

    for (let i = 1n; i <= 10n; i++) {
      await time.increase(24 * 3600); // 1d
      expect(await mt.ozPerToken()).to.equal(ozPerTokenBase - 5000000n * i / 365n);
    }
  });

  it("getOzAmount", async function () {
    const {mt} = await loadFixture(deployTestFixture);
    expect(await mt.ozPerToken()).to.equal(1000000000n);
    expect(await mt.getOzAmount(1000e9)).to.equal(1000e9);

    await time.increase(7 * 24 * 3600); // 7d
    expect(await mt.ozPerToken()).to.equal(999952055n);
    expect(await mt.getOzAmount(1000e9)).to.equal(999952055000n);
  });

  it("updateAnnualFeeRate: errors", async function () {
    const {mt, alice} = await loadFixture(deployTestFixture);
    await expect(mt.connect(alice).updateAnnualFeeRate(0.005e9))
      .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount");

    await expect(mt.updateAnnualFeeRate(0.11e9))
      .to.be.revertedWithCustomError(mt, "AnnualFeeRateTooLarge");
  });

  it("updateAnnualFeeRate: ok", async function () {
    const {mt} = await loadFixture(deployTestFixture);

    let ozPerTokenBase = 1000000000n; // 1.0
    let annualFeeRate = 0.0025e9; // 0.25%
    let ozPerTokenBaseTime = currDayStartTS;
    expect(await mt.annualFeeRate()).to.equal(annualFeeRate);
    expect(await mt.ozPerTokenBase()).to.equal(ozPerTokenBase);

    await time.increase(14 * 24 * 3600); // 14d
    ozPerTokenBaseTime += 14 * SECONDS_PER_DAY;
    ozPerTokenBase -= 2500000n * 14n / 365n;
    annualFeeRate = 0.005e9; // 0.5%
    await expect(mt.updateAnnualFeeRate(annualFeeRate))
      .to.emit(mt, "UpdateAnnualFeeRate")
      .withArgs(annualFeeRate, ozPerTokenBase, ozPerTokenBaseTime);
    expect(await mt.annualFeeRate()).to.equal(annualFeeRate);
    expect(await mt.ozPerTokenBase()).to.equal(ozPerTokenBase);
    expect(await mt.ozPerTokenBaseTime()).to.equal(ozPerTokenBaseTime);

    await time.increase(30 * 24 * 3600); // 30d
    ozPerTokenBaseTime += 30 * SECONDS_PER_DAY;
    ozPerTokenBase -= 5000000n * 30n / 365n;
    annualFeeRate = 0.002e9; // 0.2%
    await expect(mt.updateAnnualFeeRate(annualFeeRate))
      .to.emit(mt, "UpdateAnnualFeeRate")
      .withArgs(annualFeeRate, ozPerTokenBase, ozPerTokenBaseTime);
    expect(await mt.annualFeeRate()).to.equal(annualFeeRate);
    expect(await mt.ozPerTokenBase()).to.equal(ozPerTokenBase);
    expect(await mt.ozPerTokenBaseTime()).to.equal(ozPerTokenBaseTime);
  });

  it("updateAnnualFeeRate: twice in the same day", async function () {
    const {mt} = await loadFixture(deployTestFixture);

    await time.increase(30 * 24 * 3600); // 30d
    expect(await mt.annualFeeRate()).to.equal(0.0025e9);
    expect(await mt.ozPerToken()).to.equal(999794521n);
    expect(await mt.ozPerTokenBase()).to.equal(1000000000n);
    expect(await mt.ozPerTokenBaseTime()).to.equal(currDayStartTS);

    await mt.updateAnnualFeeRate(0.003e9);
    expect(await mt.annualFeeRate()).to.equal(0.003e9);
    expect(await mt.ozPerToken()).to.equal(999794521n);
    expect(await mt.ozPerTokenBase()).to.equal(999794521n);
    expect(await mt.ozPerTokenBaseTime()).to.equal(currDayStartTS + 30 * SECONDS_PER_DAY);

    await mt.updateAnnualFeeRate(0.004e9);
    expect(await mt.annualFeeRate()).to.equal(0.004e9);
    expect(await mt.ozPerToken()).to.equal(999794521n);
    expect(await mt.ozPerTokenBase()).to.equal(999794521n);
    expect(await mt.ozPerTokenBaseTime()).to.equal(currDayStartTS + 30 * SECONDS_PER_DAY);
  });

  it("forcedTransfer: onlyOwner", async function () {
    const {mt, alice, bob} = await loadFixture(deployTestFixture);
    await expect(mt.connect(alice).forcedTransfer(alice.address, bob.address, 1000e9, "0x12", "0x34"))
      .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount");
  });

  it("forcedTransfer: ok", async function () {
    const {mt, owner, operator, alice, bob} = await loadFixture(deployTestFixture);
    await mt.connect(operator).ccReceiveMintBudgetManually(1000e9);
    await mt.connect(operator).mintTo(alice.address, 1000e9, 123);
    await mt.connect(operator).mintTo(alice.address, 1000e9, 123);

    await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 200e9, "0x12", "0x34"))
      .to.emit(mt, "ForcedTransfer")
      .withArgs(alice.address, bob.address, 200e9, "0x12", "0x34")

    await expect(mt.connect(owner).forcedTransfer(alice.address, bob.address, 500e9, "0x12", "0x34"))
      .to.changeTokenBalances(mt, [alice, bob], [-500e9, 500e9]);
  });

  describe("ccManually", function () {

    it("ccSendMintBudgetManually", async function () {
      const {mt, reserveFeed, operator, alice} = await loadFixture(deployTestFixture);
      await expect(mt.connect(alice).ccSendMintBudgetManually(1000e9))
        .to.be.revertedWithCustomError(mt, "NotOperator");

      await reserveFeed.setReserve(2000e9);
      await mt.connect(operator).increaseMintBudget(2000e9);
      await expect(mt.connect(operator).ccSendMintBudgetManually(1000e9))
        .to.emit(mt, "CCSendMintBudgetManually")
        .withArgs(1000e9);
    });

    it("ccReceiveMintBudgetManually", async function () {
      const {mt, operator, alice} = await loadFixture(deployTestFixture);
      await expect(mt.connect(alice).ccReceiveMintBudgetManually(1000e9))
        .to.be.revertedWithCustomError(mt, "NotOperator");

      await expect(mt.connect(operator).ccReceiveMintBudgetManually(1000e9))
        .to.emit(mt, "CCReceiveMintBudgetManually")
        .withArgs(1000e9);
    });

  });

  describe("MTokenMain", function () {

    it("setFeeCollector: onlyOwner", async function () {
      const {mt, alice} = await loadFixture(deployTestFixture);
      
      await expect(mt.connect(alice).setFeeCollector(alice.address))
        .to.be.revertedWithCustomError(mt, "OwnableUnauthorizedAccount");

      await expect(mt.setFeeCollector(zeroAddr))
        .to.be.revertedWithCustomError(mt, "ZeroAddress");
    });

    it("setFeeCollector: ok", async function () {
      const {mt, owner, feeCollector, alice} = await loadFixture(deployTestFixture);

      await mt.connect(owner).setFeeCollector(alice.address);
      expect(await mt.feeCollector()).to.equal(feeCollector.address);

      await mt.connect(owner).setFeeCollector(alice.address);
      expect(await mt.feeCollector()).to.equal(alice.address);
    });

    it("reconcile: NotFeeCollector", async function () {
      const {mt, alice} = await loadFixture(deployTestFixture);
      await expect(mt.connect(alice).reconcileSupply(1000e9))
        .to.be.revertedWithCustomError(mt, "NotFeeCollector");
    });

    it("reconcile: TooEarlyToReconcile", async function () {
      const {mt, feeCollector} = await loadFixture(deployTestFixture);
      expect(await mt.lastReconcileTime()).to.equal(currDayStartTS);
      await time.increase(12345);
      await expect(mt.connect(feeCollector).reconcileSupply(123))
        .to.be.revertedWithCustomError(mt, "TooEarlyToReconcile");
    });

    it("reconcile: ReserveNotEnough", async function () {
      const {mt, reserveFeed, operator, feeCollector} = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(10000e9);
      await mt.connect(operator).increaseMintBudget(10000e9);

      await time.increase(SECONDS_PER_DAY); // 1d
      await expect(mt.connect(feeCollector).reconcileSupply(1000e9))
        .to.be.revertedWithCustomError(mt, "ReserveNotEnough")
        .withArgs(10000e9, 10999924661000n);
    });

    it("reconcile: ok", async function () {
      const {mt, reserveFeed, operator, feeCollector} = await loadFixture(deployTestFixture);
      const ozAmount = BigInt(10000e9);
      const annualFeeRate = BigInt(0.0025e9);
      const feeRateBase = BigInt(1e9);

      await reserveFeed.setReserve(ozAmount);
      await mt.connect(operator).increaseMintBudget(ozAmount);
      expect(await mt.totalTokenObligation()).to.equal(ozAmount);

      await time.increase(SECONDS_PER_DAY); // 1d
      const tokenAmount1 = ozAmount * feeRateBase / (feeRateBase - annualFeeRate/365n);
      const feeAmount = tokenAmount1 - ozAmount;
      await expect(mt.connect(feeCollector).reconcileSupply(feeAmount))
        .to.emit(mt, "ReconcileSupply")
        .withArgs(
          currDayStartTS, // lastReconcileTime
          currDayStartTS + SECONDS_PER_DAY, // thisReconcileTime
          feeAmount);
    });

    it("increaseMintBudget", async function () {
      // TODO
    });

  });

});
