// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

interface IUniswapV2Migrator {
    function migrate(address token, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external;
}
