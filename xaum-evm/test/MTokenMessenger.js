const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { 
  deployTestFixture, getTS,
  addrTo32Bytes, scaleUp,
  zeroAddr, fakeSolanaAddr, fakeSolanaAddr2,
} = require("./MTokenTestUtils.js");

const zeroBytes32 = '0x0000000000000000000000000000000000000000000000000000000000000000';

// pad zeros to left
function addrToBytes32(addr) {
  return addr.toLowerCase().replace('0x', '0x000000000000000000000000');
}


describe("MTokenMessenger", function () {

  describe("MTokenMessengerBase", function () {

    it("onlyOwner", async function () {
      const {mtMsg, alice} = await loadFixture(deployTestFixture);

      const testCases = [
        mtMsg.connect(alice).requestUpgradeToAndCall(alice.address, "0x1234"),
        mtMsg.connect(alice).setDelay(100000),
        mtMsg.connect(alice).revokeNextUpgrade(),
      ];

      for (const testCase of testCases) {
        await expect(testCase)
          .to.be.revertedWithCustomError(mtMsg, "OwnableUnauthorizedAccount")
          .withArgs(alice.address);
      }
    });

    it("setDelay", async function () {
      const {mtMsg} = await loadFixture(deployTestFixture);
      await expect(mtMsg.setDelay(3599)).to.be.revertedWithCustomError(mtMsg, "DelayTooSmall");
      await expect(mtMsg.setDelay(7 * 24 * 3600 + 1)).to.be.revertedWithCustomError(mtMsg, "DelayTooLarge");
      await mtMsg.setDelay(3600 * 2); // ok
    });

  });

  describe("MTokenMessenger (CCIP)", function () {

    it("init", async function () {
      const {mt, mtMsg, owner, ccipRouter} = await loadFixture(deployTestFixture);

      expect(await mtMsg.owner()).to.equal(owner.address);
      expect(await mtMsg.ccClient()).to.equal(mt.target);
      expect(await mtMsg.getRouter()).to.equal(ccipRouter.target);
    });

    it("setAllowedPeer", async function () {
      const {mtMsg, alice, bob} = await loadFixture(deployTestFixture);

      await expect(mtMsg.connect(alice).setAllowedPeer(123, bob.address, true, 20))
        .to.be.revertedWithCustomError(mtMsg, 'OwnableUnauthorizedAccount')
        .withArgs(alice);

      const testCases = [
        [123, alice.address],
        [456, bob.address],
        [789, fakeSolanaAddr],
        [987, "0x1987"],
      ];

      // allow
      for (const [chainSelector, messenger] of testCases) {
        expect(await mtMsg.allowedPeer(chainSelector, messenger)).to.deep.equal([false, 0]);
        await expect(mtMsg.setAllowedPeer(chainSelector, messenger, true, 20))
          .to.emit(mtMsg, "AllowedPeer")
          .withArgs(chainSelector, messenger.toLowerCase(), true);
      }

      // disallow
      for (const [chainSelector, messenger] of testCases) {
        expect(await mtMsg.allowedPeer(chainSelector, messenger)).to.deep.equal([true, 20]);
        await expect(mtMsg.setAllowedPeer(chainSelector, messenger, false, 20))
          .to.emit(mtMsg, "AllowedPeer")
          .withArgs(chainSelector, messenger.toLowerCase(), false);
      }
    });

    it("error: NotInAllowListed", async function () {
      const {mtMsg, ccipRouter, alice, bob} = await loadFixture(deployTestFixture);

      await expect(mtMsg.connect(alice).sendTokenToChain(123, mtMsg.target, bob.address, 10000, "0x12"))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());

      await expect(mtMsg.connect(alice).sendMintBudgetToChain(123, mtMsg.target, 10000, "0x34"))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());

      const msgId = ethers.keccak256("0x1234");
      await expect(ccipRouter.callCcipReceive(mtMsg, [msgId, 123, mtMsg.target, "0xda7a", []]))
        .to.be.revertedWithCustomError(mtMsg, "NotInAllowListed")
        .withArgs(123, mtMsg.target.toLowerCase());
    });

    it("calcFee", async function () {
      const {mt, mtMsg, reserveFeed, operator, alice, bob} = await loadFixture(deployTestFixture);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));

      const testCases = [
        [mt.target, bob.address],
        [fakeSolanaAddr, fakeSolanaAddr2],
        ["0x123456", "0x7890ABCD"],
      ];

      for (const [messageReceiver, tokenReceiver] of testCases) {
        const [fee1, msg1] = await mtMsg.calculateCCSendTokenFeeAndMessage(
          123, messageReceiver, alice.address, tokenReceiver, scaleUp(20000), "0x0e472a");
        expect(fee1).to.deep.equal(3200000n);
        expect(msg1[1]).to.include("0x0000000000000000000000000000000000000000000000000000000000000002");

        const [fee2, msg2] = await mtMsg.calculateCcSendMintBudgetFeeAndMessage(
          123, messageReceiver, scaleUp(50000), "0x0e472a");
        expect(fee2).to.deep.equal(1280000n);
        expect(msg2[1]).to.include("0x0000000000000000000000000000000000000000000000000000000000000003");
      }
    });

    it("sendTokenToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, ccipRouter, reserveFeed,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtMsg.setAllowedPeer(123, mtMsgSide.target, true, 20);
      await mtMsgSide.setAllowedPeer(100, mtMsg.target, true, 20);
      await mtSide.setMessenger(mtMsgSide.target);
      await mtSide.setMessenger(mtMsgSide.target);
      await mt.setMessenger(mtMsg.target);
      await mt.setMessenger(mtMsg.target);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);

      // ok
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, scaleUp(2000), "0x0e472a",
          {value: 3200000}
        )
      ).to.emit(mt, "CCSendToken").withArgs(alice.address, bob.address.toLowerCase(), scaleUp(2000))
        .to.emit(mtMsg, "CCSendToken");
      const msgId = await ccipRouter.lastMsgId();
      // console.log('msgId:', msgId);

      // return extra ether
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, scaleUp(3000), "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [alice.address, ccipRouter.target], 
        [-3200000, 3200000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, bob.address, scaleUp(4000), "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InsufficientFee")
        .withArgs(3200000, 1900000);

      // other side
      await expect(ccipRouter.callCcipReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveToken")
        .withArgs(alice.address.toLowerCase(), bob.address, scaleUp(2000));
      expect(await mt.balanceOf(alice.address)).to.equal(scaleUp(15000));
      expect(await mtSide.balanceOf(bob.address)).to.equal(scaleUp(2000));

      // invalid recipient length
      await expect(
        mtMsg.connect(alice).sendTokenToChain(
          123, mtMsgSide.target, "0x12345678", scaleUp(1000), "0x0e472a",
          {value: 3200000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InvalidRecipientLength")
        .withArgs(20, 4);

      // more test cases
      const testCases = [
        [bob.address, addrTo32Bytes(bob.address), "14", 0x14],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20", 0x20],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03", 0x03],
      ];
      for (const [receiverAddr, bytes32, lenHex, addrLen] of testCases) {
        const chainSel = 10000 + addrLen;
        const msgAddr = '0x' + (0x1000000000100000000010000000001000000000n + BigInt(addrLen)).toString(16);
        await mtMsg.setAllowedPeer(chainSel,msgAddr, true, addrLen);
        const expectedData = '0x'
          + '0000000000000000000000000000000000000000000000000000000000000002'
          + '0000000000000000000000000000000000000000000000000000000000000040'
          + '00000000000000000000000000000000000000000000000000000000000000e0'
          + '0000000000000000000000000000000000000000000000000000000000000060'
          + '00000000000000000000000000000000000000000000000000000000000000a0'
          + '00000000000000000000000000000000000000000000000000000000000007d0'
          + '0000000000000000000000000000000000000000000000000000000000000014'
          + addrTo32Bytes(alice.address) // sender
          + '00000000000000000000000000000000000000000000000000000000000000' + lenHex
          + bytes32 // receiver
          ;
        const tx = mtMsg.connect(alice).sendTokenToChain(
          chainSel, msgAddr, receiverAddr, scaleUp(2000), "0x0e472a",
          {value: 3200000}
        );
        await tx;
        const msgId = await ccipRouter.lastMsgId();
        await expect(tx).to.emit(mtMsg, "CCSendToken")
          .withArgs(msgId, expectedData);
        await expect(tx).to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), scaleUp(2000));
      }
    });

    it("sendMintBudgetToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, ccipRouter, reserveFeed,
        operator} = await loadFixture(deployTestFixture);
      await mtMsg.setAllowedPeer(123, mtMsgSide.target, true, 20);
      await mtMsgSide.setAllowedPeer(100, mtMsg.target, true, 20);
      await mtSide.setMessenger(mtMsgSide.target);
      await mtSide.setMessenger(mtMsgSide.target);
      await mt.setMessenger(mtMsg.target);
      await mt.setMessenger(mtMsg.target);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));

      // ok
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, scaleUp(5000), "0x0e472a",
          {value: 1280000}
        )
      ).to.emit(mt, "CCSendMintBudget").withArgs(scaleUp(5000))
        .to.emit(mtMsg, "CCSendMintBudget");
      const msgId = await ccipRouter.lastMsgId();
      // console.log('msgId:', msgId);

      // return extra ether
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, scaleUp(6000), "0x0e472a",
          {value: 2000000}
        )
      ).to.changeEtherBalances(
        [operator.address, ccipRouter.target], 
        [-1280000, 1280000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(operator).sendMintBudgetToChain(
          123, mtMsgSide.target, scaleUp(7000), "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InsufficientFee")
        .withArgs(1280000, 1270000);
    
      // other side
      await expect(ccipRouter.callCcipReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveMintBudget")
        .withArgs(scaleUp(5000));
      expect(await mtSide.mintBudget()).to.equal(scaleUp(5000));
    });

  });

  describe("MTokenMessenger (LayerZero)", function () {

    it("init", async function () {
      const {mt, mtMsg, owner, ccipRouter} = await loadFixture(deployTestFixture);

      expect(await mtMsg.owner()).to.equal(owner.address);
      expect(await mtMsg.ccClient()).to.equal(mt.target);
      expect(await mtMsg.getRouter()).to.equal(ccipRouter.target);
    });

    it("transferOwnership", async function () {
      const {mtMsg, owner, alice, bob} = await loadFixture(deployTestFixture);
      await expect(mtMsg.connect(alice).transferOwnership(bob))
        .to.be.revertedWithCustomError(mtMsg, "OwnableUnauthorizedAccount");

      await mtMsg.connect(owner).transferOwnership(bob); // starts 2-step transfer
      expect(await mtMsg.pendingOwner()).to.equal(bob.address);
      expect(await mtMsg.owner()).to.equal(owner.address);

      await mtMsg.connect(bob).acceptOwnership(); // gov delay is 0, accept immediately
      expect(await mtMsg.owner()).to.equal(bob.address);
    });

    it("lzSetPeer", async function () {
      const {mtMsg, alice, bob} = await loadFixture(deployTestFixture);
      const aliceAddr32 = addrToBytes32(alice.address);
      const bobAddr32 = addrToBytes32(bob.address);
      expect(await mtMsg.peers(123)).to.equal(zeroBytes32);
      expect(await mtMsg.peers(456)).to.equal(zeroBytes32);

      await expect(mtMsg.connect(alice).lzSetPeer(123, bobAddr32, 20))
        .to.be.revertedWithCustomError(mtMsg, 'OwnableUnauthorizedAccount')
        .withArgs(alice);

      await expect(mtMsg.lzSetPeer(123, aliceAddr32, 20))
        .to.emit(mtMsg, "PeerSet").withArgs(123, aliceAddr32);
      await expect(mtMsg.lzSetPeer(456, bobAddr32, 20))
        .to.emit(mtMsg, "PeerSet").withArgs(456, bobAddr32);
      expect(await mtMsg.peers(123)).to.equal(aliceAddr32);
      expect(await mtMsg.peers(456)).to.equal(bobAddr32);

      await expect(mtMsg.lzSetPeer(123, zeroBytes32, 20))
        .to.emit(mtMsg, "PeerSet").withArgs(123, zeroBytes32);
      expect(await mtMsg.peers(123)).to.equal(zeroBytes32);
      expect(await mtMsg.peers(456)).to.equal(bobAddr32);
    });

    it("error: NoPeer", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint, reserveFeed,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtSide.setMessenger(mtMsgSide);
      await mtSide.setMessenger(mtMsgSide);
      await mt.setMessenger(mtMsg);
      await mt.setMessenger(mtMsg);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);

      await expect(mtMsg.connect(alice).lzSendTokenToChain(123, bob.address, scaleUp(10000), "0x12"))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer").withArgs(123);

      await expect(mtMsg.connect(operator).lzSendMintBudgetToChain(123, scaleUp(10000), "0x34"))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer").withArgs(123);

      const callLzReceiveArgs = [
        mtMsg,
        [123, addrToBytes32(alice.address), 888], // Origin
        addrToBytes32(alice.address), // _guid,
        "0x", // payload
        zeroAddr, // address
        zeroBytes32, // _data,
      ];
      await expect(lzEndpoint.callLzReceive(...callLzReceiveArgs))
        .to.be.revertedWithCustomError(mtMsg, "NoPeer")
        .withArgs(123);
    });

    it("calcFee", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, reserveFeed,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtSide.setMessenger(mtMsgSide);
      await mtSide.setMessenger(mtMsgSide);
      await mt.setMessenger(mtMsg);
      await mt.setMessenger(mtMsg);
      await reserveFeed.setReserve(scaleUp(1000000));
      await mt.connect(operator).increaseMintBudget(scaleUp(500000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mtMsg.setPeer(123, addrToBytes32(mtMsgSide.target));

      const nativeFee2 = await mtMsg.lzCalculateSendMintBudgetFee(
        123, scaleUp(50000), "0x0e472a");
      expect(nativeFee2).to.deep.equal(1280000n);

      const testCases = [bob.address, fakeSolanaAddr, "0x123456"];
      for (const receiverAddr of testCases) {
        const nativeFee1 = await mtMsg.lzCalculateSendTokenFee(
          123, alice.address, receiverAddr, scaleUp(20000), "0x0e472a");
        expect(nativeFee1).to.deep.equal(3200000n);
      }
    });

    it("sendTokenToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint, reserveFeed,
        operator, alice, bob} = await loadFixture(deployTestFixture);
      await mtMsg.lzSetPeer(123, addrToBytes32(mtMsgSide.target), 20);
      await mtMsgSide.lzSetPeer(100, addrToBytes32(mtMsg.target), 20);
      await mtSide.setMessenger(mtMsgSide.target);
      await mtSide.setMessenger(mtMsgSide.target);
      await mt.setMessenger(mtMsg.target);
      await mt.setMessenger(mtMsg.target);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);

      // do not return extra ether
      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, scaleUp(3000), "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [alice.address, lzEndpoint.target], 
        [-4000000, 4000000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, scaleUp(4000), "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWith("LZ_INSUFFICIENT_FEE");

      // other side
      await mtMsg.connect(alice).lzSendTokenToChain(
        123, bob.address, scaleUp(5000), "0x0e472a",
        {value: 3200000}
      );
      const msgId = await lzEndpoint.lastMsgId();
      // console.log('msgId:', msgId);
      await expect(lzEndpoint.callLzReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveToken")
        .withArgs(alice.address.toLowerCase(), bob.address, scaleUp(5000));
      expect(await mt.balanceOf(alice.address)).to.equal(scaleUp(12000));
      expect(await mtSide.balanceOf(bob.address)).to.equal(scaleUp(5000));

      // invalid recipient length
      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, "0x12345678", scaleUp(1000), "0x0e472a",
          {value: 3200000}
        )
      ).to.be.revertedWithCustomError(mtMsg, "InvalidRecipientLength")
        .withArgs(20, 4);

      // more test cases
      const testCases = [
        [bob.address, addrTo32Bytes(bob.address), "14", 0x14],
        [fakeSolanaAddr, fakeSolanaAddr.replace("0x", ""), "20", 0x20],
        ["0x123456", "1234560000000000000000000000000000000000000000000000000000000000", "03", 0x03],
      ];
      for (const [receiverAddr, bytes32, lenHex, addrLen] of testCases) {
        const eid = 10000 + addrLen;
        const peerAddr = '0x' + (0x1000000000100000000010000000001000000000n + BigInt(addrLen)).toString(16);
        await mtMsg.lzSetPeer(eid, addrToBytes32(peerAddr), addrLen);
        const expectedData = '0x'
          + '0000000000000000000000000000000000000000000000000000000000000002'
          + '0000000000000000000000000000000000000000000000000000000000000040'
          + '00000000000000000000000000000000000000000000000000000000000000e0'
          + '0000000000000000000000000000000000000000000000000000000000000060'
          + '00000000000000000000000000000000000000000000000000000000000000a0'
          + '00000000000000000000000000000000000000000000000000000000000007d0'
          + '0000000000000000000000000000000000000000000000000000000000000014'
          + addrTo32Bytes(alice.address) // sender
          + '00000000000000000000000000000000000000000000000000000000000000' + lenHex
          + bytes32 // receiver
          ;
        const tx = mtMsg.connect(alice).lzSendTokenToChain(
          eid, receiverAddr, scaleUp(2000), "0x0e472a",
          {value: 3200000}
        );
        await tx;
        const msgId = await lzEndpoint.lastMsgId();
        await expect(tx).to.emit(mtMsg, "CCSendTokenLZ")
          .withArgs(msgId, expectedData);
        await expect(tx).to.emit(mt, "CCSendToken")
          .withArgs(alice.address, receiverAddr.toLowerCase(), scaleUp(2000));
      }
    });

    it("sendMintBudgetToChain", async function () {
      const {mt, mtSide, mtMsg, mtMsgSide, lzEndpoint, reserveFeed,
        operator, alice} = await loadFixture(deployTestFixture);
      await mtMsg.setPeer(123, addrToBytes32(mtMsgSide.target));
      await mtMsgSide.setPeer(100, addrToBytes32(mtMsg.target));
      await mtSide.setMessenger(mtMsgSide.target);
      await mtSide.setMessenger(mtMsgSide.target);
      await mt.setMessenger(mtMsg.target);
      await mt.setMessenger(mtMsg.target);
      await reserveFeed.setReserve(scaleUp(100000));
      await mt.connect(operator).increaseMintBudget(scaleUp(50000));
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);
      await mt.connect(operator).mintTo(alice.address, scaleUp(20000), 0);

      // ok
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, scaleUp(5000), "0x0e472a",
          {value: 1280000}
        )
      ).to.emit(mt, "CCSendMintBudget").withArgs(scaleUp(5000))
        .to.emit(mtMsg, "CCSendMintBudgetLZ");
      const msgId = await lzEndpoint.lastMsgId();
      // console.log('msgId:', msgId);

      // do not return extra ether
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, scaleUp(6000), "0x0e472a",
          {value: 4000000}
        )
      ).to.changeEtherBalances(
        [operator.address, lzEndpoint.target], 
        [-4000000, 4000000]);
    
      // fee not enough
      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, scaleUp(7000), "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWith("LZ_INSUFFICIENT_FEE");
    
      // other side
      await expect(lzEndpoint.callLzReceiveByMsgId(msgId))
        .to.emit(mtSide, "CCReceiveMintBudget")
        .withArgs(scaleUp(5000));
      expect(await mtSide.mintBudget()).to.equal(scaleUp(5000));
    });

    it("pause", async function () {
      const {mtMsg, owner, operator, alice, bob} = await loadFixture(deployTestFixture);

      expect(await mtMsg.lzPaused()).to.equal(false);
      await expect(mtMsg.connect(alice).setLZPaused(true))
        .to.be.revertedWithCustomError(mtMsg, "OwnableUnauthorizedAccount")
        .withArgs(alice);

      await mtMsg.connect(owner).setLZPaused(true); // ok
      expect(await mtMsg.lzPaused()).to.equal(true);

      await expect(
        mtMsg.connect(alice).lzSendTokenToChain(
          123, bob.address, 4000, "0x0e472a",
          {value: 1900000}
        )
      ).to.be.revertedWith("LZ_PAUSED");

      await expect(
        mtMsg.connect(operator).lzSendMintBudgetToChain(
          123, 7000, "0x0e472a",
          {value: 1270000}
        )
      ).to.be.revertedWith("LZ_PAUSED");
    });

  });

});