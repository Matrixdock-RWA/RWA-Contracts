// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Delayable.sol";
import "./interfaces/ICustomerManager.sol";
import "./interfaces/IBullionMinter.sol";
import "./interfaces/IUniswapV3PoolState.sol";

contract XAUMSwapPool is Delayable {

    using SafeERC20 for IERC20;

    uint constant PRICE_FACTOR_BASE = 10000;

    address public xaum;
    address public xaumPriceOracle;

    address public customerManager;
    uint public priceFactorWeekday;
    uint public priceFactorWeekend;

    uint public weekdayStartTime;
    uint public weekdayDuration; // normal is 5 days, buy maybe meet some vacation, so make it configable

    address public dexPool; // we use ethereum uniswap v3 xaum/usdt pool, which usdt is token1, and usdt must 6 decimal!
    uint public priceDeviationRatio; // price = getPrice() must follow: (1 - priceDeviationRatio / PRICE_FACTOR_BASE) * dex swap price <= price.
    bool public priceCheck;

    address public tokenHolder;
    address public nextTokenHolder;
    uint64 public etNextTokenHolder;

    mapping(address => bool) public tokenWhiteList;

    event Swap(address indexed user, address tokenIn, uint amountIn, uint amountOut);
    event SetTokenHolderEffected(address newAddr);
    event SetTokenHolderRequest(address oldAddr, address newAddr, uint64 et);
    event Withdraw(address indexed token, address receiver, uint amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _operator,
        address _revoker,
        address _customerManager,
        address _xaum,
        address _xaumPriceOracle,
        address _tokenHolder,
        address _dexPool
    ) public initializer {
        __XAUMSwap_init(
            _owner,
            _operator,
            _revoker,
            _customerManager,
            _xaum,
            _xaumPriceOracle,
            _tokenHolder,
            _dexPool
        );
    }

    function __XAUMSwap_init(
        address _owner,
        address _operator,
        address _revoker,
        address _customerManager,
        address _xaum,
        address _xaumPriceOracle,
        address _tokenHolder,
        address _dexPool
    ) internal onlyInitializing {
        __Delayable_init(_owner, _operator, _revoker);
        customerManager = _customerManager;
        xaum = _xaum;
        xaumPriceOracle = _xaumPriceOracle;
        tokenHolder = _tokenHolder;
        dexPool = _dexPool;
    }

    function setTokenHolder(address newHolder) public onlyOwner {
        _checkZeroAddress(newHolder);
        uint64 et = etNextTokenHolder;
        if (newHolder == nextTokenHolder && et != 0 && et < block.timestamp) {
            tokenHolder = newHolder;
            emit SetTokenHolderEffected(newHolder);
        } else {
            nextTokenHolder = newHolder;
            etNextTokenHolder = uint64(block.timestamp) + delay;
            emit SetTokenHolderRequest(tokenHolder, newHolder, etNextTokenHolder);
        }
    }

    function revokeNextTokenHolder() public onlyRevoker {
        etNextTokenHolder = 0;
    }

    function setPriceDeviationRatio(uint _priceDeviationRatio) public onlyOwner {
        require(_priceDeviationRatio < PRICE_FACTOR_BASE, "Invalid price deviation ratio");
        priceDeviationRatio = _priceDeviationRatio;
    }

    function setPriceCheck(bool _priceCheck) public onlyOwner {
        priceCheck = _priceCheck;
    }

    function setToken(address tokenIn, bool status) public onlyOwner {
        tokenWhiteList[tokenIn] = status;
    }

    function setDexPool(address _pool) public onlyOwner {
        _checkZeroAddress(_pool);
        dexPool = _pool;
    }

    function setPriceFactor(uint _weekday, uint _weekend) public onlyOwner {
        priceFactorWeekday = _weekday;
        priceFactorWeekend = _weekend;
    }

    function setWeekdayParam(uint _weekdayStartTime, uint _weekdayDuration) public onlyOwner {
        weekdayStartTime = _weekdayStartTime;
        weekdayDuration = _weekdayDuration;
    }

    function swap(address tokenIn, uint amountIn) public {
        require(ICustomerManager(customerManager).inWhiteList(msg.sender), "Not In WhiteList");
        require(tokenWhiteList[tokenIn], "Invalid token");

        uint price = getPrice();
        if (priceCheck) {
            uint dexPrice = getUniswapV3PoolTWAPPrice();
            require(dexPrice * (PRICE_FACTOR_BASE - priceDeviationRatio) / PRICE_FACTOR_BASE <= price, "Oracle price too low");
            require(dexPrice * (PRICE_FACTOR_BASE + priceDeviationRatio) / PRICE_FACTOR_BASE >= price, "Oracle price too high");
        }
        uint decimal = IERC20Metadata(tokenIn).decimals();
        uint amountOut = amountIn * 10 ** (18 + 8 - decimal) / price; // price is in 8 decimal
        require(amountOut <= getXAUMBalance(), "Invalid amountOut");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(xaum).safeTransfer(msg.sender, amountOut);
        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    function deposit(address token, uint amount) public onlyOperator {
        IERC20(token).safeTransferFrom(tokenHolder, address(this), amount);
    }

    function withdraw(address token, uint256 amount) public onlyOperator {
        IERC20(token).safeTransfer(tokenHolder, amount);
        emit Withdraw(token, tokenHolder, amount);
    }

    function getPrice() public view returns (uint) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(xaumPriceOracle);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (inWeekday()) {
            return uint(price) * (priceFactorWeekday + PRICE_FACTOR_BASE) / PRICE_FACTOR_BASE;
        }
        return uint(price) * (priceFactorWeekend + PRICE_FACTOR_BASE) / PRICE_FACTOR_BASE;
    }

    function getXAUMBalance() public view returns (uint) {
        return IERC20(xaum).balanceOf(address(this));
    }

    function getUniswapV3PoolTWAPPrice() public view returns (uint) {
        IUniswapV3PoolState pool = IUniswapV3PoolState(dexPool); //https://etherscan.io/address/0x3b27144eca83157E13332a75D45F0205c39C6698
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 7200; // 2 hours ago
        secondsAgos[1] = 0; // current time
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 tickAvg = (tickCumulatives[1] - tickCumulatives[0]) / 7200;
        uint160 sqrtPriceX96 = getSqrtRatioAtTick(int24(tickAvg));
        // 10 ** 20 is 10 ** (18 - 6 + 8), 18 is xaum decimal, 6 is usdt decimal, 8 is oracle price decimal and token0 is xaum.
        return 10 ** 20 * uint(sqrtPriceX96) * uint(sqrtPriceX96) / 2 ** 192; // convert uniswap v3 price decimal to chainlink aum price decimal.
    }

    function inWeekday() public view returns (bool) {
        uint timestamp = block.timestamp;
        return (timestamp - weekdayStartTime) % 7 days < weekdayDuration;
    }

    // from uniswap v3 Tick Math
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), 'T');

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
