// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

// 引入 UniswapV2Pair 接口，用于读取池子储备数据
import "../interfaces/IUniswapV2Pair.sol";

// 引入 SafeMath 库，提供安全的加减乘除等操作，防止整数溢出
import "./SafeMath.sol";

/// @title Uniswap V2 工具库
/// @notice 提供 Pair 地址计算、储备查询、价格和数量换算等纯函数，供 Router 或其它合约调用
library UniswapV2Library {
    using SafeMath for uint256; // 为 uint 类型启用 SafeMath

    /// @notice 对两个代币地址进行排序，保证 token0 < token1
    /// @dev Pair 合约内部按地址升序保存储备，外部也需同样排序以匹配
    /// @param tokenA 任意 ERC20 地址
    /// @param tokenB 任意 ERC20 地址
    /// @return token0 较小地址
    /// @return token1 较大地址
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "UniswapV2Library: IDENTICAL_ADDRESSES");
        // 按数值大小排序
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2Library: ZERO_ADDRESS");
    }

    /// @notice 计算任意两种代币在 factory 下 Pair 合约地址，无需外部调用
    /// @dev 按 CREATE2 公式：address = hash(0xff, factory, salt, init_code_hash)[12:]
    /// @param factory  UniswapV2Factory 合约地址
    /// @param tokenA   代币 A 地址
    /// @param tokenB   代币 B 地址
    /// @return pair    预测生成的 Pair 合约地址
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        // 1. 排序得到 token0, token1
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        // 2. 计算 keccak256(init_code_hash) 并拼接 factory 和 salt
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", // 前缀
                            factory, // factory 地址
                            keccak256(abi.encodePacked(token0, token1)), // salt = keccak256(token0, token1)
                            hex"c779f884b0d3b96c99d18260ba7f1b2c9a66dcddcacbcdf30f304d308cd4976e" // Pair 初始化代码哈希
                        )
                    )
                )
            )
        );
    }

    /// @notice 查询并返回某对的储备，按 tokenA/tokenB 顺序
    /// @param factory  UniswapV2Factory 地址
    /// @param tokenA   路径输入代币
    /// @param tokenB   路径输出代币
    /// @return reserveA 与 tokenA 对应的储备数量
    /// @return reserveB 与 tokenB 对应的储备数量
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        // 1. 按照内部排序得到 token0
        (address token0,) = sortTokens(tokenA, tokenB);
        // 2. 调用 Pair.getReserves() 获取储备 (reserve0, reserve1)
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        // 3. 根据调用者的 tokenA 是 token0 还是 token1 来决定返回顺序
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice 按比例换算：给定 amountA 和当前储备 reserveA/reserveB，计算等价的 amountB
    /// @param amountA   输入资产 A 数量
    /// @param reserveA  池子中 A 的储备
    /// @param reserveB  池子中 B 的储备
    /// @return amountB  等价的 B 数量
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        // amountB = amountA * reserveB / reserveA
        amountB = amountA.mul(reserveB) / reserveA;
    }

    /// @notice 给定输入量 amountIn，和池子储备，计算最大可获得的 output 量
    /// @dev 扣除 0.3% 手续费后使用恒定乘积公式
    /// @param amountIn    输入资产数量
    /// @param reserveIn   池子中输入资产的储备
    /// @param reserveOut  池子中输出资产的储备
    /// @return amountOut  最大可获得的输出资产数量
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        // 1. 扣除 0.3% 手续费：乘以 997/1000
        uint256 amountInWithFee = amountIn.mul(997);
        // 2. 计算输出：amountOut = amountInWithFee * reserveOut / (reserveIn*1000 + amountInWithFee)
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    /// @notice 给定期望的输出量 amountOut，计算需要的最小输入量 amountIn
    /// @param amountOut   期望获取的输出量
    /// @param reserveIn   池子中输入资产储备
    /// @param reserveOut  池子中输出资产储备
    /// @return amountIn   需要的输入资产数量（向上取整）
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        // 反推公式：amountIn = ceil(reserveIn*amountOut*1000 / ((reserveOut-amountOut)*997))
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    /// @notice 对一个兑换路径 path，一次性计算每跳的输出量
    /// @param factory  工厂地址，用于查询每一对的储备
    /// @param amountIn 第一跳的输入量
    /// @param path     兑换路径，如 [A, B, C, D]
    /// @return amounts 每一跳的输出量数组，与 path 等长
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        // 1. 初始化数组，第一个为输入量
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        // 2. 依次计算下一跳输出
        for (uint256 i = 0; i < path.length - 1; i++) {
            // 查询当前跳的储备
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            // 计算输出
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice 对一个兑换路径 path，一次性反向计算每跳需要的输入量
    /// @param factory   工厂地址
    /// @param amountOut 最后一跳期望输出量
    /// @param path      兑换路径
    /// @return amounts  每一跳所需的输入量数组
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        // 1. 初始化数组，最后一个为期望输出量
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        // 2. 反向迭代，计算每跳所需输入
        for (uint256 i = path.length - 1; i > 0; i--) {
            // 查询储备
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            // 计算输入
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
