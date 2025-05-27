// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IWETH.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";

/// @title Uniswap V2 路由器合约 (Router01)
/// @notice 本合约封装了对多个 Pair 合约的交互，提供一站式的添加/移除流动性和多跳兑换功能
/// @dev 与 UniswapV2Pair 只管理单一交易对不同，Router 负责路径计算、资金调度和 ETH/WETH 转换
contract UniswapV2Router01 {
    // —— 基础状态变量 ——

    /// @notice UniswapV2Factory 合约地址，用于创建或查询 Pair
    address public immutable factory;
    /// @notice WETH 合约地址，包装 ETH 以支持 ERC20 接口
    address public immutable WETH;

    /// @dev 在截止时间之后调用的交易会 revert
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    /// @param _factory V2 Factory 合约地址
    /// @param _WETH    WETH 合约地址
    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    /// @notice 接收 ETH，只允许来自 WETH 合约的转账
    receive() external payable {
        assert(msg.sender == WETH);
    }

    // **** 添加流动性 ****

    /// @dev 私有逻辑：计算在给定期望和最小值下，实际要提供多少 tokenA 和 tokenB
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired, // 用户愿意投入的 A 数量
        uint256 amountBDesired, // 用户愿意投入的 B 数量
        uint256 amountAMin, // 最低需投入的 A（滑点保护）
        uint256 amountBMin // 最低需投入的 B（滑点保护）
    ) private returns (uint256 amountA, uint256 amountB) {
        // 1. 如果 Pair 不存在，则先创建
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 2. 查询当前池子的储备
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);

        // 3. 如果池子空，则直接按愿意投入的量来
        if (reserveA == 0 && reserveB == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            // 4. 否则按当前价格比例计算最优 amountB
            uint256 amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                // 5. 检查滑点
                require(amountBOptimal >= amountBMin, "INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 6. 价格反向计算最优 amountA
                uint256 amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @notice 向任意 ERC20/ERC20 交易对添加流动性
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // 1. 计算实际需要转入 Pair 的数量
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        // 2. 得到 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 3. 将 tokenA/B 从用户账户转入 Pair
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        // 4. 调用 Pair.mint 铸造 LP 代币，发给 to
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    /// @notice 向 ERC20/ETH 交易对添加流动性（自动处理 WETH 包装）
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // 1. 计算可用 WETH 与 token 的数量
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value, // msg.value 作为 ETH 输入
            amountTokenMin,
            amountETHMin
        );
        // 2. 得到 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        // 3. 将用户的 ERC20 token 转入 Pair
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        // 4. 把 ETH 转给 WETH 合约，得到 WETH
        IWETH(WETH).deposit{value: amountETH}();
        // 5. 将 WETH 转入 Pair
        assert(IWETH(WETH).transfer(pair, amountETH));
        // 6. 铸造 LP 代币
        liquidity = IUniswapV2Pair(pair).mint(to);
        // 7. 如果 msg.value 超过实际用掉的 ETH，就退回剩余部分
        if (msg.value > amountETH) {
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
        }
    }

    // **** 移除流动性 ****

    /// @notice 从 ERC20/ERC20 池子移除流动性
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        // 1. 找到 Pair 合约并将 LP token 转入
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        // 2. 调用 burn，得到 amount0、amount1
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);
        // 3. 恢复用户期待的 (A,B) 顺序
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        // 4. 滑点保护
        require(amountA >= amountAMin, "INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "INSUFFICIENT_B_AMOUNT");
    }

    /// @notice 从 ERC20/ETH 池子移除流动性（自动 unwrap WETH）
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        // 1. 先按 token/WETH 池子移除流动性到本合约
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), // 先到本合约
            deadline
        );
        // 2. 转回 ERC20 token 给用户
        TransferHelper.safeTransfer(token, to, amountToken);
        // 3. WETH -> ETH，再转给用户
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /// @notice 带 Permit 的移除流动性（一次性 approve + remove）
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB) {
        // 1. permit 授权 Router 扣除 LP token
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        // 2. 调用 removeLiquidity
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /// @notice 带 Permit 的 ERC20/ETH 池子移除流动性
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH) {
        // 授权
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        // 移除流动性
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** 多跳交换 (Swap) ****

    /// @dev 私有循环 swap，按 path 中的每一对依次调用 Pair.swap
    function _swap(uint256[] memory amounts, address[] memory path, address _to) private {
        for (uint256 i = 0; i < path.length - 1; i++) {
            // 1. 当前跳的输入/输出 token
            (address input, address output) = (path[i], path[i + 1]);
            // 2. 标准化的 token0/token1 顺序
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            // 3. 本跳输出数量
            uint256 amountOut = amounts[i + 1];
            // 4. 将输出量分配到 amount0Out 或 amount1Out
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            // 5. 确定下一跳的接收地址：若不是最后一跳，则是下一个 Pair
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            // 6. 调用当前 Pair 的 swap
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    /// @notice 给定 amountIn，按 path 多跳兑换，至少输出 amountOutMin
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        // 1. 计算每一跳的输出量
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[path.length - 1] >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        // 2. 将输入 token 转到第一跳的 Pair
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        // 3. 执行多跳 swap
        _swap(amounts, path, to);
    }

    /// @notice 给定期望输出 amountOut，按 path 反向计算并完成 swap
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        // 1. 反向计算每跳输入量
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        // 2. 转入第一跳
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        // 3. 执行多跳 swap
        _swap(amounts, path, to);
    }

    // **** ETH 相关快捷 swap ****

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        // 1. 用 msg.value 计算多跳输出
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[path.length - 1] >= amountOutMin, "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT");
        // 2. 包装 ETH -> WETH 并转入第一对
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        // 3. 执行 swap
        _swap(amounts, path, to);
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        // 解包 WETH -> ETH 并转给 to
        IWETH(WETH).withdraw(amounts[path.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[path.length - 1]);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[path.length - 1] >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[path.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[path.length - 1]);
    }

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // 退回未使用的 ETH
        if (msg.value > amounts[0]) {
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
        }
    }

    // **** 价格和数量计算封装 ****

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
