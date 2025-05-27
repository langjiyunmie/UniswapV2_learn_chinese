// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IWETH.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";

contract UniswapV2Router02 {
    using SafeMath for uint;

    address public immutable factory;
    address public immutable WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** 添加流动性 核心计算函数 ****
    function _addLiquidity(
        address tokenA, // 交易对中代币 A 的合约地址
        address tokenB, // 交易对中代币 B 的合约地址
        uint amountADesired, // 用户希望投入的 A 数量
        uint amountBDesired, // 用户希望投入的 B 数量
        uint amountAMin, // 最小接受的 A 数量（滑点保护）
        uint amountBMin // 最小接受的 B 数量（滑点保护）
    ) internal virtual returns (uint amountA, uint amountB) {
        // 如果该交易对尚未创建，则通过 Factory 创建它
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 从工厂和库中查询当前池子里的储备量 reserveA 和 reserveB
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(
            factory,
            tokenA,
            tokenB
        );
        // 如果池子为空（首次添加流动性），就直接使用用户期望的金额
        if (reserveA == 0 && reserveB == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            // 否则按当前价格比例，计算投入 amountADesired 时，B 应投入的最优数量
            uint amountBOptimal = UniswapV2Library.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            // 如果最优 B 数量不超过用户愿意投入的 B 数量
            if (amountBOptimal <= amountBDesired) {
                // 检查最优 B 是否满足滑点保护
                require(
                    amountBOptimal >= amountBMin,
                    "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
                );
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                // 否则，按用户愿意投入的 B 数量，反向计算最优的 A 数量
                uint amountAOptimal = UniswapV2Library.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                // 断言最优 A 不会超过用户期望
                assert(amountAOptimal <= amountADesired);
                // 检查最优 A 是否满足滑点保护
                require(
                    amountAOptimal >= amountAMin,
                    "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
                );
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }
    }

    // **** 用户调用：添加 ERC20/ERC20 池子流动性 ****
    function addLiquidity(
        address tokenA, // 代币 A 地址
        address tokenB, // 代币 B 地址
        uint amountADesired, // 希望投入的 A 数量
        uint amountBDesired, // 希望投入的 B 数量
        uint amountAMin, // 最小投入 A（滑点保护）
        uint amountBMin, // 最小投入 B（滑点保护）
        address to, // LP 代币接收地址
        uint deadline // 截止时间
    )
        external
        virtual
        ensure(deadline)
        returns (
            uint amountA, // 实际投入的 A 数量
            uint amountB, // 实际投入的 B 数量
            uint liquidity // 铸造的 LP 代币数量
        )
    {
        // 1. 计算实际要投入的 A 和 B
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        // 2. 根据 Factory 和路径计算出对应的 Pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 3. 将用户的 A、B 代币从他们的地址转入到 Pair 合约
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        // 4. 调用 Pair 合约的 mint 方法，向 `to` 地址铸造 LP 代币
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // **** 用户调用：添加 ERC20/ETH 池子流动性 ****
    function addLiquidityETH(
        address token, // ERC20 代币地址
        uint amountTokenDesired, // 希望投入的 token 数量
        uint amountTokenMin, // 最小投入 token（滑点保护）
        uint amountETHMin, // 最小投入 ETH（滑点保护）
        address to, // LP 代币接收地址
        uint deadline // 截止时间
    )
        external
        payable
        virtual
        ensure(deadline)
        returns (
            uint amountToken, // 实际投入的 token 数量
            uint amountETH, // 实际包裹并投入的 ETH 数量
            uint liquidity // 铸造的 LP 代币数量
        )
    {
        // 1. 计算实际要投入的 token 和 ETH（使用 msg.value 作为 ETH 期望值）
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        // 2. 计算对应的 Pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        // 3. 将用户的 ERC20 token 转入 Pair 合约
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        // 4. 将 ETH 包装为 WETH 并转入 Pair 合约
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        // 5. 调用 Pair.mint 铸造 LP 代币到 `to`
        liquidity = IUniswapV2Pair(pair).mint(to);
        // 6. 如果用户发送的 ETH 超过实际用量，将剩余部分退回（dust refund）
        if (msg.value > amountETH) {
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
        }
    }

    // **** 移除流动性 ****

    /// @notice 从 ERC20/ERC20 池子中移除流动性
    /// @param tokenA       交易对中代币 A 的地址
    /// @param tokenB       交易对中代币 B 的地址
    /// @param liquidity    要销毁的 LP 代币数量
    /// @param amountAMin   最小可接受的 A 数量（滑点保护）
    /// @param amountBMin   最小可接受的 B 数量（滑点保护）
    /// @param to           基础资产接收地址
    /// @param deadline     截止时间戳
    /// @return amountA     实际取回的 A 数量
    /// @return amountB     实际取回的 B 数量
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual ensure(deadline) returns (uint amountA, uint amountB) {
        // 1. 计算 Pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 2. 将用户的 LP 代币从 msg.sender 转入到 Pair 合约
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        // 3. 调用 Pair.burn，将相应比例的基础代币发送到 `to`，并返回两种代币数量
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        // 4. 根据 tokenA/tokenB 的排序，映射出正确的 amountA 和 amountB
        (address token0, ) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        // 5. 滑点保护：确保取回的数量不低于用户指定的最小值
        require(
            amountA >= amountAMin,
            "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
        );
    }

    /// @notice 从 ERC20/ETH 池子中移除流动性（自动 unwrap WETH）
    /// @param token          ERC20 代币地址
    /// @param liquidity      要销毁的 LP 代币数量
    /// @param amountTokenMin 最小可接受的 ERC20 数量
    /// @param amountETHMin   最小可接受的 ETH 数量
    /// @param to             接收基础资产的地址
    /// @param deadline       截止时间戳
    /// @return amountToken   实际取回的 ERC20 数量
    /// @return amountETH     实际取回的 ETH 数量
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        public
        virtual
        ensure(deadline)
        returns (uint amountToken, uint amountETH)
    {
        // 1. 复用 ERC20/ERC20 移除逻辑，将取回的 Token 和 WETH 先发送到本合约
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        // 2. 将取回的 ERC20 代币转给最终接收者
        TransferHelper.safeTransfer(token, to, amountToken);
        // 3. 将 WETH 解包为 ETH
        IWETH(WETH).withdraw(amountETH);
        // 4. 将解包后的 ETH 转给最终接收者
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /// @notice 带 permit 的 ERC20/ERC20 池子移除流动性，免先 approve 步骤
    /// @param tokenA       代币 A 地址
    /// @param tokenB       代币 B 地址
    /// @param liquidity    要销毁的 LP 数量
    /// @param amountAMin   最小可接受的 A 数量
    /// @param amountBMin   最小可接受的 B 数量
    /// @param to           接收地址
    /// @param deadline     截止时间戳
    /// @param approveMax   是否授权最大值
    /// @param v, r, s      EIP-2612 签名参数
    /// @return amountA     实际取回的 A 数量
    /// @return amountB     实际取回的 B 数量
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual returns (uint amountA, uint amountB) {
        // 1. 计算 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 2. 根据 approveMax 确定授权额度
        uint value = approveMax ? type(uint).max : liquidity;
        // 3. 调用 Pair.permit，使用签名授权 Router 转移 LP 代币
        IUniswapV2Pair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        // 4. 授权后直接调用常规移除流动性逻辑
        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }

    /// @notice 带 permit 的 ERC20/ETH 池子移除流动性（免 approve + 自动 unwrap）
    /// @param token          ERC20 代币地址
    /// @param liquidity      要销毁的 LP 数量
    /// @param amountTokenMin 最小可接受的 ERC20 数量
    /// @param amountETHMin   最小可接受的 ETH 数量
    /// @param to             接收地址
    /// @param deadline       截止时间戳
    /// @param approveMax     是否授权最大值
    /// @param v, r, s        EIP-2612 签名参数
    /// @return amountToken   实际取回的 ERC20 数量
    /// @return amountETH     实际取回的 ETH 数量
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual returns (uint amountToken, uint amountETH) {
        // 1. 计算 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        // 2. 确定授权额度
        uint value = approveMax ? type(uint).max : liquidity;
        // 3. 使用签名调用 permit 进行授权
        IUniswapV2Pair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        // 4. 授权后调用移除 ETH 版本逻辑（包含 unwrap WETH）
        (amountToken, amountETH) = removeLiquidityETH(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** 移除流动性（支持带转账手续费的代币） ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token, // 要从中移除流动性的 ERC20 代币地址（可能在 transfer 时收取手续费）
        uint liquidity, // 用户希望销毁的 LP 代币数量
        uint amountTokenMin, // 最小可接受的 ERC20 代币数（滑点保护）
        uint amountETHMin, // 最小可接受的 ETH 数量（滑点保护）
        address to, // 最终接收取回资产的地址
        uint deadline // 截止时间戳，过期则 revert
    ) public virtual ensure(deadline) returns (uint amountETH) {
        // 调用通用 removeLiquidity，先将 token/WETH 发送到本合约，不做滑点对 token 的严格检查
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), // 暂时收取到本合约
            deadline
        );
        // 将本合约持有的所有 token（已扣除手续费后的实际余额）发给用户
        TransferHelper.safeTransfer(
            token,
            to,
            IERC20(token).balanceOf(address(this))
        );
        // 将收到的 WETH 解包为 ETH
        IWETH(WETH).withdraw(amountETH);
        // 将解包后的 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /// @notice 带 permit 且支持手续费代币的移除流动性版本
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token, // 要移除的 ERC20 代币地址
        uint liquidity, // 要销毁的 LP 代币数量
        uint amountTokenMin, // 最小接受的 ERC20 数量
        uint amountETHMin, // 最小接受的 ETH 数量
        address to, // 最终接收资产的地址
        uint deadline, // 截止时间戳
        bool approveMax, // 是否对最大值进行授权
        uint8 v, // EIP-2612 签名 v 分量
        bytes32 r, // EIP-2612 签名 r 分量
        bytes32 s // EIP-2612 签名 s 分量
    ) external virtual returns (uint amountETH) {
        // 计算对应的 Pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        // 根据 approveMax 决定授权额度（最大或精确 liquidity）
        uint value = approveMax ? type(uint).max : liquidity;
        // 使用 EIP-2612 的 permit 方法授权 Router 花费用户的 LP 代币
        IUniswapV2Pair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        // 授权后调用上述支持手续费代币的移除函数，自动 unwrap WETH 并转 ETH 给用户
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** 核心多跳 Swap 函数 ****
    // 要求最初的输入代币已被发送到路径中的第一个 Pair 合约
    function _swap(
        uint[] memory amounts, // 按路径计算出的每一步的输入/输出数量
        address[] memory path, // 兑换路径数组，如 [tokenA, tokenB, tokenC]
        address _to // 最终接收输出代币的地址
    ) internal virtual {
        // 遍历每一跳 (从 path[0]→path[1], path[1]→path[2], ...)
        for (uint i; i < path.length - 1; i++) {
            // 确定本跳的输入和输出代币
            (address input, address output) = (path[i], path[i + 1]);
            // 排序确定 token0，用于正确指定 swap 参数
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            // 本跳应当输出的数量
            uint amountOut = amounts[i + 1];
            // 根据排序，决定 amount0Out/amount1Out
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOut) // input 为 token0，则输出到 token1
                : (amountOut, uint(0)); // input 为 token1，则输出到 token0
            // 确定本跳 swap 的接收地址：如果不是最后一跳，接收方是下一个 Pair
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to; // 最后一跳则直接发给 _to
            // 调用对应 Pair 合约的 swap 方法执行兑换
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @notice 精确输入代币，多跳兑换到目标代币
    function swapExactTokensForTokens(
        uint amountIn, // 精确的输入数量
        uint amountOutMin, // 最小可接受的输出数量（滑点保护）
        address[] calldata path, // 兑换路径
        address to, // 最终接收地址
        uint deadline // 截止时间戳
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        // 1. 计算整条路径的输出数组 amounts
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        // 2. 验证最终输出至少 amountOutMin
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        // 3. 将输入代币从用户地址转到首个 Pair 合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行多跳 swap
        _swap(amounts, path, to);
    }

    /// @notice 反向计算目标输出，最多消耗 amountInMax，完成多跳兑换
    function swapTokensForExactTokens(
        uint amountOut, // 精确的目标输出数量
        uint amountInMax, // 最大可消耗输入数量
        address[] calldata path, // 兑换路径
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        // 1. 反向计算各跳所需输入 amounts
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 验证首跳所需输入不超过 amountInMax
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        // 3. 转入首跳 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行多跳 swap
        _swap(amounts, path, to);
    }

    /// @notice 精确 ETH 输入，兑换多跳目标 ERC20
    function swapExactETHForTokens(
        uint amountOutMin, // 最小可接受的输出数量
        address[] calldata path, // 路径，首项必须为 WETH
        address to,
        uint deadline
    )
        external
        payable
        virtual
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 路径校验：首位必须是 WETH
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        // 1. 计算输出 amounts
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        // 2. 验证最终输出满足滑点保护
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        // 3. 将 ETH 包装为 WETH 并转入首个 Pair
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(
            IWETH(WETH).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        // 4. 执行多跳 swap
        _swap(amounts, path, to);
    }

    /// @notice 精确输出 ETH，多跳兑换，多余输入不退
    function swapTokensForExactETH(
        uint amountOut, // 精确的目标 ETH 输出
        uint amountInMax, // 最大可消耗的输入代币数量
        address[] calldata path, // 路径，末位必须为 WETH
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        // 路径校验
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        // 1. 反向计算需要的输入 amounts
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 验证首跳输入不超限
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        // 3. 转入首跳 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行 swap 到本合约
        _swap(amounts, path, address(this));
        // 5. 将收到的 WETH 解包为 ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        // 6. 转给用户
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice 精确代币输入，多跳兑换至 ETH（多余 ETH 不退）
    function swapExactTokensForETH(
        uint amountIn, // 输入代币数量
        uint amountOutMin, // 最小可接受的 ETH 输出
        address[] calldata path, // 路径，末位必须为 WETH
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        // 路径校验
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        // 1. 计算输出 WETH 数量
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        // 2. 验证满足滑点保护
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        // 3. 将输入转到首个 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行 swap 到合约自身
        _swap(amounts, path, address(this));
        // 5. 解包 WETH 为 ETH 并转给用户
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice 精确 ETH 输出，多跳兑换，多余 ETH 退还
    function swapETHForExactTokens(
        uint amountOut, // 精确的目标输出代币数量
        address[] calldata path, // 路径，首项必须是 WETH
        address to,
        uint deadline
    )
        external
        payable
        virtual
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 路径校验
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        // 1. 反向算出需要的 ETH (WETH)
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 验证用户发送的 ETH 足够
        require(
            amounts[0] <= msg.value,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        // 3. 包装并转入首跳 Pair
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(
            IWETH(WETH).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        // 4. 执行多跳 swap
        _swap(amounts, path, to);
        // 5. 退还多余的 ETH
        if (msg.value > amounts[0]) {
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // 要求调用之前已经将输入代币发送到路径中的第一个 Pair
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path, // 兑换路径数组，如 [tokenA, tokenB, tokenC]
        address _to // 最终接收输出的地址
    ) internal virtual {
        // 遍历路径中的每一次跳转
        for (uint i; i < path.length - 1; i++) {
            // 本跳的输入和输出代币
            (address input, address output) = (path[i], path[i + 1]);
            // 确定 token0 排序用于价格计算
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            // 获取对应的 Pair 合约
            IUniswapV2Pair pair = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, input, output)
            );
            uint amountInput;
            uint amountOutput;
            {
                // 限制作用域以避免栈过深
                // 读取当前储备量
                (uint reserve0, uint reserve1, ) = pair.getReserves();
                // 根据排序决定哪一个是输入/输出储备
                (uint reserveInput, uint reserveOutput) = input == token0
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);
                // 实际输入量 = 当前 Pair 地址下的输入代币余额 - 上次储备
                amountInput = IERC20(input).balanceOf(address(pair)).sub(
                    reserveInput
                );
                // 根据 Uniswap 公式计算此次可输出的数量
                amountOutput = UniswapV2Library.getAmountOut(
                    amountInput,
                    reserveInput,
                    reserveOutput
                );
            }
            // 按排序决定 amount0Out 或 amount1Out
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOutput)
                : (amountOutput, uint(0));
            // 确定本跳 swap 的接收地址：若非最后一跳，则为下个 Pair，否则为 _to
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            // 执行 swap，将输出发往 to
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @notice 精确输入代币，多跳兑换，支持 Fee-On-Transfer 代币
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, // 精确的输入数量
        uint amountOutMin, // 最小可接受的最终输出（滑点保护）
        address[] calldata path, // 兑换路径
        address to, // 最终接收地址
        uint deadline // 截止时间
    ) external virtual ensure(deadline) {
        // 将输入数量从用户钱包转入首跳 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        // 记录调用前目标代币接收地址的余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        // 调用支持手续费代币的核心 swap
        _swapSupportingFeeOnTransferTokens(path, to);
        // 验证实际收到的输出至少满足滑点保护
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    /// @notice 精确输入 ETH，多跳兑换至 ERC20，支持 Fee-On-Transfer 代币
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, // 最小可接受输出数量
        address[] calldata path, // 兑换路径（首项必须是 WETH）
        address to, // 最终接收地址
        uint deadline // 截止时间
    ) external payable virtual ensure(deadline) {
        // 路径校验：首位必须为 WETH
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        uint amountIn = msg.value;
        // 将 ETH 包装为 WETH
        IWETH(WETH).deposit{value: amountIn}();
        // 转入首跳 Pair
        assert(
            IWETH(WETH).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amountIn
            )
        );
        // 记录调用前目标代币接收地址的余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        // 执行支持手续费代币的 swap
        _swapSupportingFeeOnTransferTokens(path, to);
        // 验证收到的输出至少满足滑点保护
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    /// @notice 精确输入代币，多跳兑换至 ETH，支持 Fee-On-Transfer 代币
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, // 精确的输入数量
        uint amountOutMin, // 最小可接受的 ETH 输出
        address[] calldata path, // 兑换路径（末项必须是 WETH）
        address to, // 最终接收地址
        uint deadline // 截止时间
    ) external virtual ensure(deadline) {
        // 路径校验：末位必须为 WETH
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        // 将输入代币转入首跳 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        // 执行支持手续费代币的 swap，输出发送到本合约
        _swapSupportingFeeOnTransferTokens(path, address(this));
        // 查询本合约收到的 WETH 数量
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        // 验证输出至少满足滑点保护
        require(
            amountOut >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        // 解包 WETH 为 ETH
        IWETH(WETH).withdraw(amountOut);
        // 将 ETH 转给最终接收地址
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** 工具函数封装 ****

    /// @notice 在给定两种储备的情况下，根据 amountA 计算等价的 amountB
    /// @param amountA    输入的 A 数量
    /// @param reserveA   池子中 A 的储备
    /// @param reserveB   池子中 B 的储备
    /// @return amountB   按当前比例计算出的 B 数量
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) public pure virtual returns (uint amountB) {
        // 直接调用 UniswapV2Library.quote，实现 amountA * reserveB / reserveA
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    /// @notice 给定输入量和池子储备，计算能输出的最大代币数量（考虑 0.3% 交易费）
    /// @param amountIn     输入的代币数量
    /// @param reserveIn    池子中输入代币的储备
    /// @param reserveOut   池子中输出代币的储备
    /// @return amountOut   可输出的目标代币数量
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure virtual returns (uint amountOut) {
        // 直接调用 UniswapV2Library.getAmountOut
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice 给定期望输出量和池子储备，反向计算所需的最小输入量（考虑 0.3% 交易费）
    /// @param amountOut    期望输出的代币数量
    /// @param reserveIn    池子中输入代币的储备
    /// @param reserveOut   池子中输出代币的储备
    /// @return amountIn    需要投入的最小输入代币数量
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) public pure virtual returns (uint amountIn) {
        // 调用 UniswapV2Library.getAmountIn
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /// @notice 给定输入量和路径，计算每跳可输出的代币数量数组
    /// @param amountIn   初始输入量
    /// @param path       多跳兑换路径
    /// @return amounts   每一步的输出量数组，长度等于 path.length
    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) public view virtual returns (uint[] memory amounts) {
        // 调用 UniswapV2Library.getAmountsOut，传入 factory 地址
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    /// @notice 给定期望最终输出量和路径，反向计算每跳所需的输入量数组
    /// @param amountOut  期望的最终输出量
    /// @param path       多跳兑换路径
    /// @return amounts   每一步所需的输入量数组，第一项为总输入量
    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) public view virtual returns (uint[] memory amounts) {
        // 调用 UniswapV2Library.getAmountsIn，传入 factory 地址
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
