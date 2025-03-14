const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers } = require("hardhat");

async function getTS(tx) {
  const block = await ethers.provider.getBlock(tx.blockNumber);
  return block.timestamp;
}

const zeroAddr = '0x0000000000000000000000000000000000000000';

const priceDec = 18n;
const xaumDec  = 18n;

function _price(n) { return n * (10n ** priceDec);}
function _xaum(n)  { return n * (10n ** xaumDec); }
function _usdt(n, decimals=18n)  { return n * (10n ** decimals); }


describe("XAUMDCAMinter", function () {

  const _maxPrice = 2700n;
  const _minPrice = 2600n;
  const _midPrice = 2640n;
  const defaultDelay = 3600; // 1h
  const defaultMaxPrice = _price(_maxPrice);
  const defaultMinPrice = _price(_minPrice);

  async function deployTestFixture(usdtDecimals = 18n) {
    const [owner, priceOperator, fundOperator, fundRecipient, revoker, dca, dca2, alice, bob] = await ethers.getSigners();

    const ERC20 = await ethers.getContractFactory("FakeERC20");
    const xaum = await ERC20.deploy("XAUM", _xaum(100_000_000n), xaumDec);
    const usdt = await ERC20.deploy("USDT", _usdt(100_000_000n, usdtDecimals), usdtDecimals);
    await xaum.transfer(alice.address, _xaum(100_000_000n));
    await usdt.transfer(alice.address, _usdt(100_000_000n, usdtDecimals));

    const NFT = await ethers.getContractFactory("FakeERC721");
    const nft = await NFT.deploy("GBAR");

    const Minter = await ethers.getContractFactory("XAUMDCAMinter");
    const minter = await upgrades.deployProxy(Minter, 
      [
        xaum.target, usdt.target,
        owner.address, revoker.address, 
        priceOperator.address, fundOperator.address, fundRecipient.address,
        defaultDelay, defaultMinPrice, defaultMaxPrice,
      ],
      {kind: "uups"},
    );

    await minter.setDCA(dca, true);

    for (const token of [usdt, xaum]) {
      const decimals = await token.decimals();
      token.amt = function(n) { return n * (10n ** decimals); }
      token.toPrice = function(n) { return _price(n / (10n ** decimals)); }
    }

    return {
      minter, usdt, xaum, nft,
      owner, priceOperator, fundOperator, fundRecipient, revoker, dca, dca2,
      alice, bob,
    }
  }

  it("init", async function() {
    const {
      minter, xaum, usdt,
      owner, priceOperator, fundOperator, fundRecipient, revoker, dca,
    } = await loadFixture(deployTestFixture);

    expect(await minter.xaum()).to.equal(xaum.target);
    expect(await minter.usdToken()).to.equal(usdt.target);
    expect(await minter.dcaMap(dca.address)).to.equal(true);
    expect(await minter.owner()).to.equal(owner.address);
    expect(await minter.revoker()).to.equal(revoker.address);
    expect(await minter.priceOperator()).to.equal(priceOperator.address);
    expect(await minter.fundOperator()).to.equal(fundOperator.address);
    expect(await minter.fundRecipient()).to.equal(fundRecipient.address);
    expect(await minter.minPrice()).to.equal(defaultMinPrice);
    expect(await minter.maxPrice()).to.equal(defaultMaxPrice);
    expect(await minter.delay()).to.equal(defaultDelay);
  });

  describe("delayed set", function () {

    let testCases = [ 
      {field: 'delay',  initVal: defaultDelay, newVal: defaultDelay * 2},
      {field: 'maxPrice',  initVal: _price(2700n), newVal: _price(2800n)},
      {field: 'minPrice',  initVal: _price(2600n), newVal: _price(2500n)},
      {field: 'priceOperator', initVal: null, newVal: '0xb0b'},
      {field: 'fundOperator', initVal: null, newVal: '0xb0b'},
      {field: 'fundRecipient', initVal: null, newVal: '0xb0b'},
      {field: 'revoker', initVal: null, newVal: '0xb0b'},
    ];
  
    for (let {field, newVal} of testCases) {
      const _Field = field[0].toUpperCase() + field.substring(1);
      const set      = 'set' + _Field;
      const revoke   = 'revokeNext' + _Field;
      const next     = 'next' + _Field;
      const etNext   = 'etNext' + _Field;
      const reqEvent = 'Set' + _Field + 'Request';
      const eftEvent = 'Set' + _Field + 'Effected';

      it(set, async function() {
        const {minter, owner, revoker, alice, bob} = await loadFixture(deployTestFixture);
        if (newVal == '0xb0b') {
          newVal = bob.address;
        }

        const initVal = await minter[field]();
        expect(await minter[next]()).to.equal(0n);
        expect(await minter[etNext]()).to.equal(0);
      
        // request: only owner
        await expect(minter.connect(alice)[set](newVal))
          .to.be.revertedWithCustomError(minter, 'OwnableUnauthorizedAccount')
          .withArgs(alice.address);
    
        // request: ok, check event
        await expect(minter.connect(owner)[set](newVal))
          .to.emit(minter, reqEvent).withArgs(initVal, newVal, anyValue);
        expect(await minter[field]()).to.equal(initVal);
        expect(await minter[next]()).to.equal(newVal);
        expect(await minter[etNext]()).to.greaterThan(0);
    
        // revoke: only revoker
        let _revoker = field == 'revoker' ? owner : revoker;
        let err = field == 'revoker' ? 'OwnableUnauthorizedAccount' : 'NotRevoker';
        await expect(minter.connect(alice)[revoke]())
          .to.be.revertedWithCustomError(minter, err)
          .withArgs(alice.address);
    
        // revoke: ok
        await minter.connect(_revoker)[revoke]();
        expect(await minter[field]()).to.equal(initVal);
        expect(await minter[next]()).to.equal(newVal);
        expect(await minter[etNext]()).to.equal(0);
    
        // request: ok, check et
        const tx1 = await minter.connect(owner)[set](newVal);
        const ts1 = await getTS(tx1);
        expect(await minter[field]()).to.equal(initVal);
        expect(await minter[next]()).to.equal(newVal);
        expect(await minter[etNext]()).to.equal(ts1 + defaultDelay);
    
        // execute: reset
        const tx2 = await minter.connect(owner)[set](newVal);
        const ts2 = await getTS(tx2);
        expect(await minter[field]()).to.equal(initVal);
        expect(await minter[next]()).to.equal(newVal);
        expect(await minter[etNext]()).to.equal(ts2 + defaultDelay);

        // execute: ok
        await time.increase(defaultDelay + 1);
        await expect(minter.connect(owner)[set](newVal))
          .to.emit(minter, eftEvent).withArgs(newVal);
        expect(await minter[field]()).to.equal(newVal);
        expect(await minter[next]()).to.equal(newVal);
        expect(await minter[etNext]()).to.equal(ts2 + defaultDelay);  

        // revoke: ok
        await minter.connect(owner)[set](initVal);
        expect(await minter[field]()).to.equal(newVal);
        expect(await minter[next]()).to.equal(initVal);
        expect(await minter[etNext]()).to.greaterThan(0);
        await minter.connect(_revoker)[revoke]();
        expect(await minter[etNext]()).to.equal(0);

      }); // end of it
    } // end of for

    it('setPrice: InvalidPriceLimit', async function() {
      const {minter, owner} = await loadFixture(deployTestFixture);

      await expect(minter.connect(owner).setMaxPrice(defaultMinPrice - 1n))
        .to.be.revertedWithCustomError(minter, 'InvalidPriceLimit')
        .withArgs(defaultMinPrice, defaultMinPrice - 1n);

      await expect(minter.connect(owner).setMinPrice(defaultMaxPrice + 1n))
        .to.be.revertedWithCustomError(minter, 'InvalidPriceLimit')
        .withArgs(defaultMaxPrice + 1n, defaultMaxPrice);
    });

  }); // end of describe

  it("privileged ops", async function () {
    const {minter, usdt, xaum, alice, bob} = await loadFixture(deployTestFixture);

    const sender = minter.connect(alice);

    const testCases = [
      [sender.setDCA(alice.address, true), 'OwnableUnauthorizedAccount'],
      [sender.setDCA(alice.address, false), 'OwnableUnauthorizedAccount'],
      [sender.withdrawERC20(usdt.target, alice.address, 1234), 'OwnableUnauthorizedAccount'],
      [sender.withdrawERC721(usdt.target, alice.address, 1234), 'OwnableUnauthorizedAccount'],
      [sender.withdrawForRebalance(usdt.target, 1234), 'NotFundOperator'],
      [sender.collectXAUm(alice.address, 1234), 'NotDCA'],
      [sender.setFixedPrice(123, 456), 'NotPriceOperator'],
      [sender.swapForXAUm(alice.address, usdt.target, 123), 'NotDCA'],
    ];

    for (const [op, err] of testCases) {
      await expect(op)
        .to.be.revertedWithCustomError(minter, err)
        .withArgs(alice.address);
    }
  });
  
  it("dca map", async function () {
    const {minter, owner, dca2} = await loadFixture(deployTestFixture);

    await expect(minter.connect(owner).setDCA(dca2.address, true))
      .to.emit(minter, 'SetDCA').withArgs(dca2.address, true);
    expect(await minter.dcaMap(dca2.address)).to.equal(true);

    await expect(minter.connect(owner).setDCA(dca2.address, false))
      .to.emit(minter, 'SetDCA').withArgs(dca2.address, false);
    expect(await minter.dcaMap(dca2.address)).to.equal(false);
  });

  it("withdrawERC20", async function () {
    const {minter, usdt, alice, bob} = await loadFixture(deployTestFixture);
    await usdt.connect(alice).transfer(minter, 12345);

    await expect(minter.withdrawERC20(usdt.target, alice.address, 1234))
      .to.changeTokenBalances(usdt, [minter, alice], [-1234, 1234]);
    await expect(minter.withdrawERC20(usdt.target, bob.address, 2345))
      .to.changeTokenBalances(usdt, [minter, bob], [-2345, 2345]);
    
    await expect(minter.withdrawERC20(usdt.target, zeroAddr, 111))
      .to.be.revertedWithCustomError(minter, 'ZeroTokenRecipient');
  });

  it("withdrawERC721", async function () {
    const {minter, nft, alice, bob} = await loadFixture(deployTestFixture);
    await nft.mint(minter, 111);
    await nft.mint(minter, 222);
    await nft.mint(minter, 333);
  
    await expect(minter.withdrawERC721(nft.target, alice.address, 111))
      .to.changeTokenBalances(nft, [minter, alice], [-1, 1]);
    await expect(minter.withdrawERC721(nft.target, bob.address, 222))
      .to.changeTokenBalances(nft, [minter, bob], [-1, 1]);

    await expect(minter.withdrawERC721(nft.target, zeroAddr, 333))
      .to.be.revertedWithCustomError(minter, 'ZeroTokenRecipient');
  });

  it("withdrawForRebalance", async function () {
    const {minter, usdt, fundOperator, fundRecipient, alice} = await loadFixture(deployTestFixture);
    await usdt.connect(alice).transfer(minter, 12345);
    await usdt.connect(alice).transfer(minter, 12345);
    
    await expect(minter.connect(fundOperator).withdrawForRebalance(usdt.target, 1234))
      .to.changeTokenBalances(usdt, [minter, fundRecipient], [-1234, 1234]);
    await expect(minter.connect(fundOperator).withdrawForRebalance(usdt.target, 2345))
      .to.emit(minter, 'WithdrawSystemFund')
      .withArgs(usdt.target, 2345);
  });

  it("claim: NotEnoughUserXAUm", async function () {
    const { usdt, xaum, minter, priceOperator,
      dca, alice, bob } = await loadFixture(deployTestFixture);
    await usdt.connect(dca).approve(minter, _xaum(100_000_000n));
    await usdt.connect(alice).transfer(dca, _xaum(50_000_000n));
    await xaum.connect(alice).transfer(minter, _xaum(50_000_000n));

    // usdt => xaum
    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 500);
    await minter.connect(dca).swapForXAUm(bob, usdt, fromAmt);
    expect(await minter.xaumBalances(dca.address, bob.address)).to.equal(toAmt);

    await expect(minter.connect(dca).collectXAUm(bob.address, toAmt + 1n))
      .to.be.revertedWithCustomError(minter, 'NotEnoughUserXAUm')
      .withArgs(bob.address, toAmt, toAmt + 1n);
  });

  it("claim: NotEnoughSystemToken", async function () {
    const { usdt, xaum, minter, priceOperator,
      dca, alice, bob } = await loadFixture(deployTestFixture);
    await usdt.connect(dca).approve(minter, _xaum(100_000_000n));
    await usdt.connect(alice).transfer(dca, _xaum(50_000_000n));
    await xaum.connect(alice).transfer(minter, _xaum(100n));

    // usdt => xaum
    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 500);
    await minter.connect(dca).swapForXAUm(bob, usdt, fromAmt);
    expect(await minter.xaumBalances(dca.address, bob.address)).to.equal(toAmt);

    await expect(minter.connect(dca).collectXAUm(bob.address, toAmt))
      .to.be.revertedWithCustomError(minter, 'NotEnoughSystemXAUm')
      .withArgs(_xaum(100n), toAmt);
  });

  it("claim: ok", async function () {
    const { usdt, xaum, minter, priceOperator,
      dca, alice, bob } = await loadFixture(deployTestFixture);
    await usdt.connect(dca).approve(minter, _xaum(100_000_000n));
    await usdt.connect(alice).transfer(dca, _xaum(50_000_000n));
    await xaum.connect(alice).transfer(minter, _xaum(50_000_000n));

    // usdt => xaum
    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 500);
    await minter.connect(dca).swapForXAUm(bob, usdt, fromAmt);
    expect(await minter.xaumBalances(dca.address, bob.address)).to.equal(toAmt);

    const claimAmt = toAmt / 2n;
    const tx1 = minter.connect(dca).collectXAUm(bob.address, claimAmt);
    await expect(tx1).to.emit(minter, 'CollectXAUm')
      .withArgs(dca.address, bob.address, claimAmt);
    await expect(tx1).to.changeTokenBalances(xaum, [minter, dca], [-claimAmt, claimAmt]);
    expect(await minter.xaumBalances(dca.address, bob.address)).to.equal(toAmt / 2n);
  });

  it("setFixedPrice: PriceOutOfRange", async function () {
    const { minter, priceOperator } = await loadFixture(deployTestFixture);

    for (const price of [defaultMinPrice - 1n, defaultMaxPrice + 1n]) {
      await expect(minter.connect(priceOperator).setFixedPrice(price, 123))
        .to.be.revertedWithCustomError(minter, 'PriceOutOfRange')
        .withArgs(price);
    }
  });

  it("setFixedPrice: ok", async function () {
    const { minter, priceOperator } = await loadFixture(deployTestFixture);

    const price = _price(_midPrice);
    const validPeriod = 300;

    const tx1 = await minter.connect(priceOperator).setFixedPrice(price, validPeriod);
    const ts1 = await getTS(tx1);
    expect(await minter.getFixedPrice()).to.deep.equal([price, ts1 + validPeriod]);

    await expect(minter.connect(priceOperator).setFixedPrice(price + 1n, validPeriod * 2))
      .to.emit(minter, 'SetFixedPrice')
      .withArgs(price + 1n, anyValue);
  });

  it("swapForXAUm: FixedPriceExpired", async function () {
    const { minter, xaum, usdt, priceOperator, dca, alice } = await loadFixture(deployTestFixture);

    const validPeriod = 300;
    const price = _price(_midPrice);

    await minter.connect(priceOperator).setFixedPrice(price, validPeriod);
    await time.increase(validPeriod + 1);

    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await expect(minter.connect(dca).swapForXAUm(alice, usdt, fromAmt))
      .to.be.revertedWithCustomError(minter, 'FixedPriceExpired');
  });

  it("swapForXAUm: InvalidUsdToken", async function() {
    const { minter, xaum, usdt, priceOperator, dca, alice } = await loadFixture(deployTestFixture);
    await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 500);

    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await expect(minter.connect(dca).swapForXAUm(alice, xaum, fromAmt))
      .to.be.revertedWithCustomError(minter, 'InvalidUsdToken');
  });

  it("swapForXAUm: ok", async function () {
    const { usdt, xaum, minter, priceOperator,
      dca, alice, bob } = await loadFixture(deployTestFixture);
    await usdt.connect(dca).approve(minter, _usdt(100_000_000n));
    await xaum.connect(dca).approve(minter, _xaum(100_000_000n));
    await usdt.connect(alice).transfer(dca, _usdt(50_000_000n));
    await xaum.connect(alice).transfer(dca, _xaum(50_000_000n));
    await xaum.connect(alice).transfer(minter, _xaum(50_000_000n));
    await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 300);

    // usdt => xaum
    const [fromAmt, toAmt] = [_usdt(_midPrice * 200n), _xaum(200n)];
    await expect(minter.connect(dca).swapForXAUm(bob, usdt, fromAmt))
      .to.emit(minter, 'SwapForXAUm')
      .withArgs(dca.address, bob.address, usdt.target, fromAmt, toAmt);
  });

  for (const usdtDecimals of [6n, 18n, 20n]) {
    it("swapForXAUm: " + usdtDecimals, async function() {
      const { usdt, xaum, minter, priceOperator,
        dca, alice, bob } = await deployTestFixture(usdtDecimals);

      expect(await usdt.decimals()).to.equal(usdtDecimals);
  
      await xaum.connect(dca).approve(minter, _xaum(100_000_000n));
      await xaum.connect(alice).transfer(minter, _xaum(50_000_000n));
      await xaum.connect(alice).transfer(dca, _xaum(50_000_000n));
  
      await minter.connect(priceOperator).setFixedPrice(_price(_midPrice), 300);
  
      await usdt.connect(alice).transfer(dca, usdt.amt(10_000_000n));
      await usdt.connect(dca).approve(minter, usdt.amt(100_000_000n));

      // usdt => xaum
      const [fromAmt1, toAmt1] = [_usdt(_midPrice * 20n, usdtDecimals), _xaum(20n)];
      const tx1 = minter.connect(dca).swapForXAUm(bob, usdt, fromAmt1);
      await expect(tx1).to.emit(minter, 'SwapForXAUm')
        .withArgs(dca.address, bob.address, usdt.target, fromAmt1, toAmt1);
      await expect(tx1).to.changeTokenBalances(usdt, [dca, minter], [-fromAmt1, fromAmt1]);
      // await expect(tx1).to.changeTokenBalances(xaum, [bob, minter], [toAmt1, -toAmt1]);
      expect(await minter.xaumBalances(dca.address, bob.address)).to.equal(toAmt1);
    });
  }

});
