const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const zeroAddr = '0x0000000000000000000000000000000000000000';

// token decimals used by the fixture
const stableDec = 6n;  // stablecoin pool (A): accepted by requestToMint
const rwaDec    = 18n; // rwa pool (B): accepted by requestToRedeem

function _stable(n) { return n * (10n ** stableDec); }
function _rwa(n)    { return n * (10n ** rwaDec); }

const DELAY_MAX = 59; // BullionMinter.DELAY_MAX

describe("BullionMinter", function () {

    async function deployTestFixture() {
        const [owner, poolA, poolB, alice, bob, other] = await ethers.getSigners();

        const ERC20 = await ethers.getContractFactory("FakeERC20");
        // stablecoins accepted by pool A (minting)
        const usdt = await ERC20.deploy("USDT", _stable(1_000_000_000n), stableDec);
        const usdc = await ERC20.deploy("USDC", _stable(1_000_000_000n), stableDec);
        // rwa tokens accepted by pool B (redeeming)
        const xaum = await ERC20.deploy("XAUM", _rwa(1_000_000_000n), rwaDec);
        const xagm = await ERC20.deploy("XAGM", _rwa(1_000_000_000n), rwaDec);

        // fund alice so she can call requestToMint / requestToRedeem
        await usdt.transfer(alice.address, _stable(1_000_000n));
        await xaum.transfer(alice.address, _rwa(1_000_000n));

        const BullionMinter = await ethers.getContractFactory("BullionMinter");
        const minter = await upgrades.deployProxy(BullionMinter,
            [
                owner.address,
                poolA.address,
                poolB.address,
                [usdt.target],  // tokensAcceptedByA
                [xaum.target],  // tokensAcceptedByB
            ],
            { kind: "uups" },
        );

        return {
            minter, usdt, usdc, xaum, xagm,
            owner, poolA, poolB, alice, bob, other,
        };
    }

    describe("initialize & configuration", function () {

        it("sets owner, pools and accepted tokens", async function () {
            const { minter, usdt, usdc, xaum, xagm, owner, poolA, poolB } =
                await loadFixture(deployTestFixture);

            expect(await minter.owner()).to.equal(owner.address);
            expect(await minter.poolAccountA()).to.equal(poolA.address);
            expect(await minter.poolAccountB()).to.equal(poolB.address);

            expect(await minter.acceptedByA(usdt.target)).to.equal(true);
            expect(await minter.acceptedByA(usdc.target)).to.equal(false);
            expect(await minter.acceptedByB(xaum.target)).to.equal(true);
            expect(await minter.acceptedByB(xagm.target)).to.equal(false);
        });

        it("initializes with multiple / empty accepted-token lists", async function () {
            const { usdt, usdc, xaum, xagm, owner, poolA, poolB } =
                await loadFixture(deployTestFixture);

            const BullionMinter = await ethers.getContractFactory("BullionMinter");

            // several tokens per pool (multi-iteration init loops)
            const multi = await upgrades.deployProxy(BullionMinter,
                [owner.address, poolA.address, poolB.address,
                 [usdt.target, usdc.target], [xaum.target, xagm.target]],
                { kind: "uups" },
            );
            expect(await multi.acceptedByA(usdt.target)).to.equal(true);
            expect(await multi.acceptedByA(usdc.target)).to.equal(true);
            expect(await multi.acceptedByB(xaum.target)).to.equal(true);
            expect(await multi.acceptedByB(xagm.target)).to.equal(true);

            // empty lists (zero-iteration init loops) — mirrors the deploy script
            const empty = await upgrades.deployProxy(BullionMinter,
                [owner.address, poolA.address, poolB.address, [], []],
                { kind: "uups" },
            );
            expect(await empty.acceptedByA(usdt.target)).to.equal(false);
            expect(await empty.acceptedByB(xaum.target)).to.equal(false);
        });

        it("cannot be re-initialized", async function () {
            const { minter, owner, poolA, poolB } = await loadFixture(deployTestFixture);
            await expect(
                minter.initialize(owner.address, poolA.address, poolB.address, [], [])
            ).to.be.revertedWithCustomError(minter, "InvalidInitialization");
        });

        it("exposes the documented constants", async function () {
            const { minter } = await loadFixture(deployTestFixture);
            expect(await minter.DELAY_MAX()).to.equal(DELAY_MAX);
            expect(await minter.PREPRICE_DECIMAL()).to.equal(6);
            expect(await minter.SLIPPAGE_DECIMAL()).to.equal(6);
        });

        for (const { setter, event, getter } of [
            { setter: "setPoolAccountA", event: "SetPoolAccountA", getter: "poolAccountA" },
            { setter: "setPoolAccountB", event: "SetPoolAccountB", getter: "poolAccountB" },
        ]) {
            describe(setter, function () {
                it("owner can update; emits event", async function () {
                    const { minter, other } = await loadFixture(deployTestFixture);
                    await expect(minter[setter](other.address))
                        .to.emit(minter, event).withArgs(other.address);
                    expect(await minter[getter]()).to.equal(other.address);
                });
                it("reverts for non-owner", async function () {
                    const { minter, alice, other } = await loadFixture(deployTestFixture);
                    await expect(minter.connect(alice)[setter](other.address))
                        .to.be.revertedWithCustomError(minter, "OwnableUnauthorizedAccount")
                        .withArgs(alice.address);
                });
                it("reverts on zero address", async function () {
                    const { minter } = await loadFixture(deployTestFixture);
                    await expect(minter[setter](zeroAddr))
                        .to.be.revertedWithCustomError(minter, "ZeroAddress");
                });
            });
        }

        for (const { setter, event, getter, tokenKey } of [
            { setter: "setAcceptedByA", event: "SetAcceptedByA", getter: "acceptedByA", tokenKey: "usdc" },
            { setter: "setAcceptedByB", event: "SetAcceptedByB", getter: "acceptedByB", tokenKey: "xagm" },
        ]) {
            describe(setter, function () {
                it("owner can add and remove a token; emits event", async function () {
                    const fixture = await loadFixture(deployTestFixture);
                    const { minter } = fixture;
                    const token = fixture[tokenKey];

                    await expect(minter[setter](token.target, true))
                        .to.emit(minter, event).withArgs(token.target, true);
                    expect(await minter[getter](token.target)).to.equal(true);

                    await expect(minter[setter](token.target, false))
                        .to.emit(minter, event).withArgs(token.target, false);
                    expect(await minter[getter](token.target)).to.equal(false);
                });
                it("reverts for non-owner", async function () {
                    const fixture = await loadFixture(deployTestFixture);
                    const { minter, alice } = fixture;
                    const token = fixture[tokenKey];
                    await expect(minter.connect(alice)[setter](token.target, true))
                        .to.be.revertedWithCustomError(minter, "OwnableUnauthorizedAccount")
                        .withArgs(alice.address);
                });
                it("reverts on zero address", async function () {
                    const { minter } = await loadFixture(deployTestFixture);
                    await expect(minter[setter](zeroAddr, true))
                        .to.be.revertedWithCustomError(minter, "ZeroAddress");
                });
            });
        }
    });

    describe("requestToMint", function () {

        const amount = _stable(1000n);

        it("transfers the stablecoin to poolAccountA and emits MintRequest", async function () {
            const { minter, usdt, xaum, poolA, alice } = await loadFixture(deployTestFixture);

            await usdt.connect(alice).approve(minter.target, amount);
            const now = await time.latest();

            await expect(
                minter.connect(alice).requestToMint(
                    usdt.target, xaum.target, amount, 123n, 45n, now, "0x1234")
            ).to.emit(minter, "MintRequest")
                .withArgs(usdt.target, xaum.target, alice.address, poolA.address,
                          amount, 123n, 45n, "0x1234");

            expect(await usdt.balanceOf(poolA.address)).to.equal(amount);
            expect(await usdt.balanceOf(alice.address)).to.equal(_stable(1_000_000n) - amount);
        });

        it("uses the current poolAccountA even after it is changed", async function () {
            const { minter, usdt, xaum, alice, other } = await loadFixture(deployTestFixture);

            await minter.setPoolAccountA(other.address);
            await usdt.connect(alice).approve(minter.target, amount);
            const now = await time.latest();

            await expect(
                minter.connect(alice).requestToMint(
                    usdt.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.emit(minter, "MintRequest")
                .withArgs(usdt.target, xaum.target, alice.address, other.address,
                          amount, 0, 0, "0x");
            expect(await usdt.balanceOf(other.address)).to.equal(amount);
        });

        it("reverts when the transferred token is not accepted by pool A", async function () {
            const { minter, usdc, xaum, alice } = await loadFixture(deployTestFixture);
            const now = await time.latest();
            await expect(
                minter.connect(alice).requestToMint(
                    usdc.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWith("INVALID_TOKEN_FOR_MINTING");
        });

        it("honors setAcceptedByA toggling", async function () {
            const { minter, usdc, xaum, poolA, alice } = await loadFixture(deployTestFixture);
            await usdc.transfer(alice.address, amount);
            await usdc.connect(alice).approve(minter.target, amount);

            // not accepted yet
            let now = await time.latest();
            await expect(
                minter.connect(alice).requestToMint(usdc.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWith("INVALID_TOKEN_FOR_MINTING");

            // accept, then it works
            await minter.setAcceptedByA(usdc.target, true);
            now = await time.latest();
            await expect(
                minter.connect(alice).requestToMint(usdc.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.emit(minter, "MintRequest");
            expect(await usdc.balanceOf(poolA.address)).to.equal(amount);
        });

        it("accepts a timestamp at the DELAY_MAX boundary and rejects one past it", async function () {
            const { minter, usdt, xaum, alice } = await loadFixture(deployTestFixture);
            await usdt.connect(alice).approve(minter.target, amount * 2n);

            // block.timestamp == timestamp + DELAY_MAX -> accepted (uses <=)
            const T1 = (await time.latest()) + 1000;
            await time.setNextBlockTimestamp(T1);
            await expect(
                minter.connect(alice).requestToMint(
                    usdt.target, xaum.target, amount, 0, 0, T1 - DELAY_MAX, "0x")
            ).to.emit(minter, "MintRequest");

            // block.timestamp == timestamp + DELAY_MAX + 1 -> rejected
            const T2 = (await time.latest()) + 1000;
            await time.setNextBlockTimestamp(T2);
            await expect(
                minter.connect(alice).requestToMint(
                    usdt.target, xaum.target, amount, 0, 0, T2 - DELAY_MAX - 1, "0x")
            ).to.be.revertedWith("INVALID_TIMESTAMP");
        });

        it("accepts a future timestamp", async function () {
            const { minter, usdt, xaum, alice } = await loadFixture(deployTestFixture);
            await usdt.connect(alice).approve(minter.target, amount);
            const future = (await time.latest()) + 10_000;
            await expect(
                minter.connect(alice).requestToMint(
                    usdt.target, xaum.target, amount, 0, 0, future, "0x")
            ).to.emit(minter, "MintRequest");
        });

        it("reverts when allowance is insufficient", async function () {
            const { minter, usdt, xaum, alice } = await loadFixture(deployTestFixture);
            const now = await time.latest();
            // no approve() call
            await expect(
                minter.connect(alice).requestToMint(usdt.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWithCustomError(usdt, "ERC20InsufficientAllowance");
        });

        it("reverts when balance is insufficient", async function () {
            const { minter, usdt, xaum, bob } = await loadFixture(deployTestFixture);
            // bob has no usdt but approves anyway
            await usdt.connect(bob).approve(minter.target, amount);
            const now = await time.latest();
            await expect(
                minter.connect(bob).requestToMint(usdt.target, xaum.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWithCustomError(usdt, "ERC20InsufficientBalance");
        });
    });

    describe("requestToRedeem", function () {

        const amount = _rwa(5n);

        it("transfers the rwa token to poolAccountB and emits RedeemRequest", async function () {
            const { minter, xaum, usdt, poolB, alice } = await loadFixture(deployTestFixture);

            await xaum.connect(alice).approve(minter.target, amount);
            const now = await time.latest();

            await expect(
                minter.connect(alice).requestToRedeem(
                    xaum.target, usdt.target, amount, 7n, 8n, now, "0xbeef")
            ).to.emit(minter, "RedeemRequest")
                .withArgs(xaum.target, usdt.target, alice.address, poolB.address,
                          amount, 7n, 8n, "0xbeef");

            expect(await xaum.balanceOf(poolB.address)).to.equal(amount);
            expect(await xaum.balanceOf(alice.address)).to.equal(_rwa(1_000_000n) - amount);
        });

        it("uses the current poolAccountB even after it is changed", async function () {
            const { minter, xaum, usdt, alice, other } = await loadFixture(deployTestFixture);

            await minter.setPoolAccountB(other.address);
            await xaum.connect(alice).approve(minter.target, amount);
            const now = await time.latest();

            await expect(
                minter.connect(alice).requestToRedeem(
                    xaum.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.emit(minter, "RedeemRequest")
                .withArgs(xaum.target, usdt.target, alice.address, other.address,
                          amount, 0, 0, "0x");
            expect(await xaum.balanceOf(other.address)).to.equal(amount);
        });

        it("reverts when the transferred token is not accepted by pool B", async function () {
            const { minter, xagm, usdt, alice } = await loadFixture(deployTestFixture);
            const now = await time.latest();
            await expect(
                minter.connect(alice).requestToRedeem(
                    xagm.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWith("INVALID_TOKEN_FOR_REDEEMING");
        });

        it("honors setAcceptedByB toggling", async function () {
            const { minter, xagm, usdt, poolB, alice } = await loadFixture(deployTestFixture);
            await xagm.transfer(alice.address, amount);
            await xagm.connect(alice).approve(minter.target, amount);

            let now = await time.latest();
            await expect(
                minter.connect(alice).requestToRedeem(xagm.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWith("INVALID_TOKEN_FOR_REDEEMING");

            await minter.setAcceptedByB(xagm.target, true);
            now = await time.latest();
            await expect(
                minter.connect(alice).requestToRedeem(xagm.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.emit(minter, "RedeemRequest");
            expect(await xagm.balanceOf(poolB.address)).to.equal(amount);
        });

        it("accepts a timestamp at the DELAY_MAX boundary and rejects one past it", async function () {
            const { minter, xaum, usdt, alice } = await loadFixture(deployTestFixture);
            await xaum.connect(alice).approve(minter.target, amount * 2n);

            const T1 = (await time.latest()) + 1000;
            await time.setNextBlockTimestamp(T1);
            await expect(
                minter.connect(alice).requestToRedeem(
                    xaum.target, usdt.target, amount, 0, 0, T1 - DELAY_MAX, "0x")
            ).to.emit(minter, "RedeemRequest");

            const T2 = (await time.latest()) + 1000;
            await time.setNextBlockTimestamp(T2);
            await expect(
                minter.connect(alice).requestToRedeem(
                    xaum.target, usdt.target, amount, 0, 0, T2 - DELAY_MAX - 1, "0x")
            ).to.be.revertedWith("INVALID_TIMESTAMP");
        });

        it("reverts when allowance is insufficient", async function () {
            const { minter, xaum, usdt, alice } = await loadFixture(deployTestFixture);
            const now = await time.latest();
            await expect(
                minter.connect(alice).requestToRedeem(xaum.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWithCustomError(xaum, "ERC20InsufficientAllowance");
        });

        it("reverts when balance is insufficient", async function () {
            const { minter, xaum, usdt, bob } = await loadFixture(deployTestFixture);
            await xaum.connect(bob).approve(minter.target, amount);
            const now = await time.latest();
            await expect(
                minter.connect(bob).requestToRedeem(xaum.target, usdt.target, amount, 0, 0, now, "0x")
            ).to.be.revertedWithCustomError(xaum, "ERC20InsufficientBalance");
        });
    });

    describe("rescue", function () {

        const stuck = _stable(777n);

        it("owner rescues ERC20 accidentally sent to the contract; emits Rescue", async function () {
            const { minter, usdc, owner, bob } = await loadFixture(deployTestFixture);
            // simulate tokens accidentally sent to the minter
            await usdc.transfer(minter.target, stuck);

            await expect(minter.connect(owner).rescue(usdc.target, bob.address, stuck))
                .to.emit(minter, "Rescue").withArgs(usdc.target, bob.address, stuck);

            expect(await usdc.balanceOf(minter.target)).to.equal(0n);
            expect(await usdc.balanceOf(bob.address)).to.equal(stuck);
        });

        it("reverts for non-owner", async function () {
            const { minter, usdc, alice, bob } = await loadFixture(deployTestFixture);
            await usdc.transfer(minter.target, stuck);
            await expect(minter.connect(alice).rescue(usdc.target, bob.address, stuck))
                .to.be.revertedWithCustomError(minter, "OwnableUnauthorizedAccount")
                .withArgs(alice.address);
        });

        it("reverts when the contract balance is insufficient", async function () {
            const { minter, usdc, owner, bob } = await loadFixture(deployTestFixture);
            // nothing transferred in
            await expect(minter.rescue(usdc.target, bob.address, stuck))
                .to.be.revertedWithCustomError(usdc, "ERC20InsufficientBalance");
        });
    });

    describe("govDelay / getDelay override", function () {
        // getDelay() returns 0; exercise it through the inherited setGovDelay path
        // (checkGovDelay reads getDelay()), and confirm delay==0 lets a valid
        // govDelay be requested/effected.
        it("setGovDelay works with the zero operational delay", async function () {
            const { minter, alice } = await loadFixture(deployTestFixture);
            const DAY = 24 * 3600;
            const OP_SET_GOV_DELAY = ethers.keccak256(ethers.toUtf8Bytes("OP_SET_GOV_DELAY"));

            await expect(minter.connect(alice).setGovDelay(DAY))
                .to.be.revertedWithCustomError(minter, "OwnableUnauthorizedAccount")
                .withArgs(alice.address);

            // first call requests (govDelay currently 0)
            await expect(minter.setGovDelay(DAY))
                .to.emit(minter, "DelayedOpRequest").withArgs(OP_SET_GOV_DELAY, 0, DAY, anyValue);
            expect(await minter.getGovDelay()).to.equal(0);

            // second call effects it
            await expect(minter.setGovDelay(DAY))
                .to.emit(minter, "DelayedOpEffected").withArgs(OP_SET_GOV_DELAY, DAY);
            expect(await minter.getGovDelay()).to.equal(DAY);
        });
    });
});
