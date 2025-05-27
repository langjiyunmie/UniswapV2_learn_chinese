// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import '../interfaces/IUniswapV2Pair.sol';
import './FixedPoint.sol';

// @title UniswapV2OracleLibrary
// @notice 工具库，用于计算 Uniswap V2 交易对的累计价格并支持高效的链上时间戳获取
library UniswapV2OracleLibrary {
    using FixedPoint for *;  // 导入 FixedPoint 库，支持定点数运算

    /**
     * @notice 获取当前区块时间戳，并将其压缩到 uint32 范围内
     * @dev Solidity 中 block.timestamp 返回 uint256，本函数对其取模，保证在 uint32
     * @return uint32 当前区块时间戳（0 到 2**32-1 范围）
     */
    function currentBlockTimestamp() internal view returns (uint32) {
        // block.timestamp % 2**32：截断为 32 位
        return uint32(block.timestamp % 2 ** 32);
    }

    /**
     * @notice 计算并返回当前的价格累积值，无需调用 sync 来节省 gas
     * @param pair 目标 Uniswap V2 交易对合约地址
     * @return price0Cumulative 累计的 token0 价格（UQ112x112 格式）
     * @return price1Cumulative 累计的 token1 价格（UQ112x112 格式）
     * @return blockTimestamp 当前区块时间戳（32 位）
     */
    function currentCumulativePrices(
        address pair
    ) internal view returns (
        uint price0Cumulative,
        uint price1Cumulative,
        uint32 blockTimestamp
    ) {
        // 获取截断后的当前区块时间戳
        blockTimestamp = currentBlockTimestamp();

        // 读取交易对合约中上次记录的累积价格
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // 获取当前储备量和上一次更新时间戳
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();

        // 如果自上次更新以来已过时间，则使用 "反事实" 方法更新累积价格
        if (blockTimestampLast != blockTimestamp) {
            // 计算自上次更新到当前的时间差（秒）
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // price0Cumulative 增加：reserve1/reserve0（UQ112x112）乘以时间差
            price0Cumulative += uint(
                FixedPoint
                    .fraction(reserve1, reserve0)
                    ._x
            ) * timeElapsed;
            // price1Cumulative 增加：reserve0/reserve1（UQ112x112）乘以时间差
            price1Cumulative += uint(
                FixedPoint
                    .fraction(reserve0, reserve1)
                    ._x
            ) * timeElapsed;
        }
    }
}