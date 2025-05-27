// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

/// @title Uniswap V2 单交易对合约
/// @notice 管理一个 Token0-Token1 交易对的流动性、兑换、手续费和价格累积
contract UniswapV2Pair is UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    // —— 常量定义 —— 

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 初始化时锁定的最小流动性，防止第一次流动性提供者抽空池子

    bytes4 private constant SELECTOR =
        bytes4(keccak256(bytes('transfer(address,uint256)')));
    // 用于低层调用 ERC20 transfer 的函数签名选择器

    // —— 核心状态变量 —— 

    address public factory;   // 创建本 Pair 的 UniswapV2Factory 地址
    address public token0;    // 交易对中的第一个代币
    address public token1;    // 交易对中的第二个代币

    uint112 private reserve0;       // 本合约持有的 token0 储备（上次同步后的值）
    uint112 private reserve1;       // 本合约持有的 token1 储备（上次同步后的值）
    uint32  private blockTimestampLast;
    // 上次调用 _update 时的区块时间戳，截断到 uint32

    uint public price0CumulativeLast;  // 累积的 token1/token0 价格 × 时间
    uint public price1CumulativeLast;  // 累积的 token0/token1 价格 × 时间
    uint public kLast;                 // 上次流动性变化时的 reserve0 × reserve1，用于手续费计算

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    // 防重入锁，确保一个交易中不会重复进入

    /// @notice 构造函数：记录 factory 地址
    constructor() {
        factory = msg.sender;
    }

    /// @notice 初始化交易对的两个代币，只能由 factory 调用一次
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN');
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice 返回当前储备和上次更新时间戳
    function getReserves()
        public view
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @dev 安全地调用 ERC20.transfer，检查返回值
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'UniswapV2: TRANSFER_FAILED'
        );
    }

    // —— 事件定义 —— 

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In, uint amount1In,
        uint amount0Out, uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @dev 更新储备并在每个区块第一次调用时累积价格
    function _update(
        uint balance0, uint balance1,
        uint112 _reserve0, uint112 _reserve1
    ) private {
        require(
            balance0 <= type(uint112).max && balance1 <= type(uint112).max,
            'UniswapV2: OVERFLOW'
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // 可溢出回绕
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // price0 = reserve1/reserve0
            price0CumulativeLast +=
                uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // price1 = reserve0/reserve1
            price1CumulativeLast +=
                uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /// @dev 如果开启手续费，铸造协议收入部分流动性给 feeTo 地址
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast;
        if (feeOn && _kLast != 0) {
            uint rootK     = Math.sqrt(uint(_reserve0).mul(_reserve1));
            uint rootKLast = Math.sqrt(_kLast);
            if (rootK > rootKLast) {
                uint numerator   = totalSupply.mul(rootK.sub(rootKLast));
                uint denominator = rootK.mul(5).add(rootKLast);
                uint liquidity   = numerator / denominator;
                if (liquidity > 0) _mint(feeTo, liquidity);
            }
        } else if (!feeOn && _kLast != 0) {
            kLast = 0;
        }
    }

    /// @notice 铸造新的流动性，返回用户铸造的 LP 数量
    /// @dev amount0/1 = 本次转入的 token0/1 数量 = 当前余额 - 旧储备
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0  = balance0.sub(_reserve0);
        uint amount1  = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // 初始流动性：sqrt(amount0*amount1) - MINIMUM_LIQUIDITY
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定
        } else {
            // 后续流动性：按比例铸造
            liquidity = Math.min(
                amount0.mul(_totalSupply) / _reserve0,
                amount1.mul(_totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice 销毁 LP，并按比例返还 underlying token0/1
    /// @param to 接收返还资产的地址
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint balance0   = IERC20(_token0).balanceOf(address(this));
        uint balance1   = IERC20(_token1).balanceOf(address(this));
        uint liquidity  = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
        amount0 = liquidity.mul(balance0) / _totalSupply;
        amount1 = liquidity.mul(balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice 执行 swap，先乐观转出再校验恒定乘积
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data)
        external lock
    {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0; uint balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            // 闪兑回调，允许调用方执行自定义逻辑并归还资产
            if (data.length > 0) IUniswapV2Callee(to)
                .uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 计算实际输入量
        uint amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        // 按 0.3% 手续费调整后的恒定乘积校验
        {
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(
                balance0Adjusted.mul(balance1Adjusted)
                    >= uint(_reserve0).mul(_reserve1).mul(1000**2),
                'UniswapV2: K'
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice 清除多余余额，将 balance - reserve 部分转给 to
    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;
        // 转走 balanceOf - reserve
        _safeTransfer(
            _token0, to,
            IERC20(_token0).balanceOf(address(this)).sub(reserve0)
        );
        _safeTransfer(
            _token1, to,
            IERC20(_token1).balanceOf(address(this)).sub(reserve1)
        );
    }

    /// @notice 强制将储备与实际余额同步（无滑点校验）
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0, reserve1
        );
    }
}
