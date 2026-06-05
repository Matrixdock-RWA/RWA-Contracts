export const zeroAddr = '0x0000000000000000000000000000000000000000';
export const fakeSolanaAddr = '0xadb988d4ab4fc55dd7069344c325e327706e1ec41f0c3db007ce32b29a4fe6ee';
export const fakeSolanaAddr2 = '0x471fe8fd552fb23b3c72c774340f553e92c37e9f79b48fd9d363a491ecd65a7b';

// pad zeros to right
export function addrTo32Bytes(addr) {
  return addr.toLowerCase().replace('0x', '') + '000000000000000000000000';
}

export async function getTS(tx) {
  const block = await ethers.provider.getBlock(tx.blockNumber);
  return block.timestamp;
}

export const SECONDS_PER_DAY = 24 * 60 * 60;
export const DEFAULT_FEE_RATE_ANNUAL = 0.0025e9; // 0.25%
export const DEFAULT_OZ_PER_TOKEN_BASE = 1.0e9; // 1.0
export const INITIAL_OZ_PER_TOKEN = 1.0e9; // 1.0

export async function deployTestFixture() {
  const [owner, operator, feeCollector, alice, bob] = await ethers.getSigners();

  const FallbackReserveFeed = await ethers.getContractFactory("FallbackReserveFeed");
  const reserveFeed = await FallbackReserveFeed.deploy(owner.address);
  await reserveFeed.setReserve(100000000);

  const MTokenMain = await ethers.getContractFactory("MTokenMain");
  const mt = await upgrades.deployProxy(MTokenMain,
    ["MTokenMain", "MTM", owner.address, operator.address, reserveFeed.target,
      DEFAULT_FEE_RATE_ANNUAL,
      DEFAULT_OZ_PER_TOKEN_BASE,
      feeCollector.address],
    {kind: "uups"}
  );

  const MTokenSide = await ethers.getContractFactory("MTokenSide");
  const mtSide = await upgrades.deployProxy(MTokenSide,
    ["MTokenSide", "MTS", owner.address, operator.address,
      DEFAULT_FEE_RATE_ANNUAL,
      DEFAULT_OZ_PER_TOKEN_BASE],
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
      unsafeAllow: [
        'constructor',
        'state-variable-immutable',
        'missing-initializer',
        'incorrect-initializer-order',
      ],
      // unsafeSkipStorageCheck: true
    },
  );
  const mtMsgSide = await upgrades.deployProxy(MTokenMessenger,
    [mtSide.target, owner.address], // init args
    {
      kind: "uups",
      constructorArgs: [ccipRouter.target, lzEndpoint.target],
      unsafeAllow: [
        'constructor',
        'state-variable-immutable',
        'missing-initializer',
        'incorrect-initializer-order',
      ],
      // unsafeSkipStorageCheck: true
    },
  );

  const MTokenRateLimiter = await ethers.getContractFactory("MTokenRateLimiter");
  const rateLimiter = await MTokenRateLimiter.deploy(mt.target, 0, 0);

  return {
    reserveFeed, ccipRouter, lzEndpoint, // fake
    mt, mtSide, mtMsg, mtMsgSide, rateLimiter, // contracts
    owner, operator, alice, bob, feeCollector
  };
}
