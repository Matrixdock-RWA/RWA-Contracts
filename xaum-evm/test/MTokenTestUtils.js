export const zeroAddr = '0x0000000000000000000000000000000000000000';
export const fakeSolanaAddr = '0xadb988d4ab4fc55dd7069344c325e327706e1ec41f0c3db007ce32b29a4fe6ee';
export const fakeSolanaAddr2 = '0x471fe8fd552fb23b3c72c774340f553e92c37e9f79b48fd9d363a491ecd65a7b';

// pad zeros to right
export function addrTo32Bytes(addr) {
  return addr.toLowerCase().replace('0x', '') + '000000000000000000000000';
}

export function scaleDown(amt) { return amt / 1e9; }
export function scaleUp(amt) { return amt * 1e9; }

// Delayed ops no longer emit one Request/Effected pair per operation; they all go through
// TimeLockerUpgradeable's generic DelayedOpRequest / DelayedOpEffected, keyed by reqHash.
// OP() derives the reqHash of a fixed-key op; the helpers below derive the arg-keyed ones.
export function OP(name) {
  return ethers.keccak256(ethers.toUtf8Bytes(name));
}

const abi = () => ethers.AbiCoder.defaultAbiCoder();

export function forcedTransferReqId(from, to, value, nonce, data, extraData) {
  const payload = abi().encode(
    ["address", "address", "uint256", "uint256", "bytes", "bytes"],
    [from, to, value, nonce, data, extraData]
  );
  return {
    reqHash: ethers.keccak256(abi().encode(["bytes32", "bytes"], [OP("OP_FORCED_TRANSFER"), payload])),
    payload,
  };
}

export function rateLimitedMsgReqId(opName, rateLimiter, index) {
  return ethers.keccak256(
    abi().encode(["bytes32", "address", "uint256"], [OP(opName), rateLimiter, index]));
}

export function addToWhitelistReqId(sender, receiver) {
  const payload = abi().encode(["bytes", "address"], [sender, receiver]);
  return {
    reqHash: ethers.keccak256(
      abi().encode(["bytes32", "bytes", "address"], [OP("OP_ADD_TO_WHITELIST"), sender, receiver])),
    payload,
  };
}

export function addAllowedPeerReqId(chainSelector, messenger, addrLen) {
  return {
    reqHash: ethers.keccak256(abi().encode(
      ["bytes32", "uint64", "bytes"], [OP("OP_ADD_ALLOWED_PEER"), chainSelector, messenger])),
    // the request slot encodes PeerInfo: bit 8 marks "allowed", low 8 bits are addrLen
    newVal: allowedPeerVal(true, addrLen),
    payload: abi().encode(["uint64", "bytes", "uint8"], [chainSelector, messenger, addrLen]),
  };
}

// mirrors MTokenMessenger._allowedPeerVal; an absent peer encodes to 0
export function allowedPeerVal(allowed, addrLen) {
  return allowed ? (1n << 8n) | BigInt(addrLen) : 0n;
}

// mirrors MTokenMessengerLZ._lzAddPeerVal; an absent peer (0, 0) encodes to 0
export function lzPeerVal(peer, addrLen) {
  return ((BigInt(peer) << 8n) | BigInt(addrLen)) & ((1n << 160n) - 1n);
}

export function lzAddPeerReqId(eid, peer, addrLen) {
  return {
    reqHash: ethers.keccak256(
      abi().encode(["bytes32", "uint32"], [OP("OP_LZ_ADD_PEER"), eid])),
    // mirrors MTokenMessengerLZ._lzAddPeerVal: the request slot packs (peer, addrLen)
    // into uint160 — addrLen in the low 8 bits, the low 152 bits of peer above it
    newVal: lzPeerVal(peer, addrLen),
    payload: abi().encode(["uint32", "bytes32", "uint8"], [eid, peer, addrLen]),
  };
}

export async function getTS(tx) {
  const block = await ethers.provider.getBlock(tx.blockNumber);
  return block.timestamp;
}

// activate the two time-locks on a freshly deployed contract (delay = govDelay = 0):
// govDelay goes first — delay can never exceed govDelay — and once govDelay is set,
// setDelay itself is time-locked (MToken: by govDelay; others: by the delay itself)
export async function setupDelay(c, delay, govDelay) {
  await c.setGovDelay(govDelay);
  await c.setGovDelay(govDelay);
  await c.setDelay(delay);
  await ethers.provider.send("evm_increaseTime", [govDelay]);
  await ethers.provider.send("evm_mine", []);
  await c.setDelay(delay);
}

export async function deployTestFixture() {
  const [owner, operator, packSigner, fakeNft, alice, bob] = await ethers.getSigners();

  const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
  const reserveFeed = await FallbackReserveFeed.deploy(owner.address);
  await reserveFeed.setReserve(100000000);

  const MTokenMain = await ethers.getContractFactory("MTokenMain");
  const mt = await upgrades.deployProxy(MTokenMain, 
    ["MTokenMain", "MTM", owner.address, operator.address, reserveFeed.target],
    {kind: "uups"}
  );

  const MTokenSide = await ethers.getContractFactory("MTokenSide");
  const mtSide = await upgrades.deployProxy(MTokenSide,
    ["MTokenSide", "MTS", owner.address, operator.address],
    {kind: "uups"}
  );

  const BullionNFT = await ethers.getContractFactory("BullionEnumerableNFT_UT");
  const nft = await upgrades.deployProxy(BullionNFT,
    ["BullionNFT", "BNFT", mt.target, packSigner.address, owner.address],
    {kind: "uups"}
  );

  const FakeRouterClient = await ethers.getContractFactory("FakeRouterClient");
  const ccipRouter = await FakeRouterClient.deploy();

  const FakeL0Endpoint = await ethers.getContractFactory("FakeL0Endpoint");
  const lzEndpoint = await FakeL0Endpoint.deploy();

  const MTokenMessenger = await ethers.getContractFactory("MTokenMessenger");
  const mtMsg = await upgrades.deployProxy(MTokenMessenger,
    [mt.target, owner.address], // init args
    {
      kind: "uups",
      constructorArgs: [ccipRouter.target, lzEndpoint.target],
      unsafeAllow: ['constructor', 'state-variable-immutable']
    },
  );
  const mtMsgSide = await upgrades.deployProxy(MTokenMessenger,
    [mtSide.target, owner.address], // init args
    {
      kind: "uups",
      constructorArgs: [ccipRouter.target, lzEndpoint.target],
      unsafeAllow: ['constructor', 'state-variable-immutable']
    },
  );

  const MTokenRateLimiter = await ethers.getContractFactory("MTokenRateLimiter");
  const rateLimiter = await upgrades.deployProxy(MTokenRateLimiter,
    [owner.address, owner.address, owner.address, 0, 0],
    {
      kind: "uups",
      constructorArgs: [mt.target],
      unsafeAllow: ['constructor', 'state-variable-immutable'],
    }
  );

  return {
    reserveFeed, ccipRouter, lzEndpoint, // fake
    mt, mtSide, nft, mtMsg, mtMsgSide, rateLimiter, // contracts
    owner, operator, packSigner, fakeNft, alice, bob,
  };
}
