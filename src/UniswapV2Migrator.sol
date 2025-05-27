// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Migrator.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/V1/IUniswapV1Exchange.sol";
import "./interfaces/V1/IUniswapV1Factory.sol";
import "./libraries/TransferHelper.sol";

/// @title Uniswap V1 → V2 流动性迁移合约
/// @notice 一键将用户在 Uniswap V1 上的流动性移植到 Uniswap V2，自动处理 Remove 和 Add 流程
contract UniswapV2Migrator {
    // —— 外部依赖接口 ——

    /// @dev Uniswap V1 Factory，用于查询某个 ERC20 Token 在 V1 的 Exchange 合约地址
    IUniswapV1Factory public immutable factoryV1;
    /// @dev Uniswap V2 Router，用于在 V2 上添加流动性（ETH + ERC20）
    IUniswapV2Router01 public immutable router;

    /// @param _factoryV1 Uniswap V1 Factory 合约地址
    /// @param _router    Uniswap V2 Router 合约地址
    constructor(address _factoryV1, address _router) {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        router = IUniswapV2Router01(_router);
    }

    /// @notice 接收 ETH 的回退函数
    /// @dev 允许 V1 兑换合约(removeLiquidity 时)和 V2 Router(addLiquidityETH 退剩余 ETH 时)向本合约转 ETH
    receive() external payable {}

    /// @notice 将 msg.sender 在 V1 上的流动性一键迁移到 V2
    /// @param token          ERC20 代币地址，要迁移的资产
    /// @param amountTokenMin 在 V2 添加流动性时，最少要接受的代币数量（用于滑点保护）
    /// @param amountETHMin   在 V2 添加流动性时，最少要接受的 ETH 数量（用于滑点保护）
    /// @param to             V2 上 LP 代币的接收地址
    /// @param deadline       交易截止时间戳，超时则 revert
    function migrate(
        address token,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external {
        // 1. 查询用户在 V1 对应 token 的 Exchange 合约
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(
            factoryV1.getExchange(token)
        );

        // 2. 查询用户在该 V1 Exchange 持有的 LP 数量
        uint liquidityV1 = exchangeV1.balanceOf(msg.sender);

        // 3. 将用户所有 V1 LP token 转移到本合约
        //    用户须提前 approve 本合约花费其 V1 LP
        require(
            exchangeV1.transferFrom(msg.sender, address(this), liquidityV1),
            "TRANSFER_FROM_FAILED"
        );

        // 4. 在 V1 上移除流动性，换回 ETH 和 ERC20
        //    这里 min 参数设为 1，deadline 设为 uint.max，滑点基本无忧
        (uint amountETHV1, uint amountTokenV1) = exchangeV1.removeLiquidity(
            liquidityV1,
            1,
            1,
            type(uint).max
        );

        // 5. 授权 V2 Router 可以花费合约持有的 V1 换回的 token
        TransferHelper.safeApprove(token, address(router), amountTokenV1);

        // 6. 在 V2 上添加流动性（ETH + token），并获取实际消耗的数据
        //    addLiquidityETH 会将 value(ETH) 和 token 一起加入池子
        (uint amountTokenV2, uint amountETHV2, ) = router.addLiquidityETH{
            value: amountETHV1
        }(token, amountTokenV1, amountTokenMin, amountETHMin, to, deadline);

        // 7. 如果 V1 取回的 token 超过在 V2 中实际用掉的量，则：
        if (amountTokenV1 > amountTokenV2) {
            // 7.1 重置 approve 为 0，良好链上公民习惯
            TransferHelper.safeApprove(token, address(router), 0);
            // 7.2 退还多余的 token 给用户
            TransferHelper.safeTransfer(
                token,
                msg.sender,
                amountTokenV1 - amountTokenV2
            );
        }
        // 8. 否则，如果 V1 取回的 ETH 超过在 V2 中实际用掉的量，则：
        else if (amountETHV1 > amountETHV2) {
            // 8.1 把多余的 ETH 转回给用户
            TransferHelper.safeTransferETH(
                msg.sender,
                amountETHV1 - amountETHV2
            );
        }
        // 9. 如果两者都恰好用完，则无需退回任何资产
    }
}
