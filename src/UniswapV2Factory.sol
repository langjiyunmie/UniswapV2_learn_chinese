// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory {
    /// @notice 收手续费的地址
    address public feeTo;
    /// @notice 有权限设置 feeTo 的地址
    address public feeToSetter;

    /// @notice 存储 token0->token1 对应的 Pair 合约地址
    mapping(address => mapping(address => address)) public getPair;
    /// @notice 所有创建过的 Pair 地址列表
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    /// @notice 返回当前已创建的 Pair 数量
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /// @notice 创建一个新的交易对 (tokenA, tokenB)
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 1. 地址不能相同
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 2. 对 tokenA、tokenB 按地址大小排序，保证一致性
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        // 3. 排序后第一个不能是零地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 4. 不能重复创建同一对
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS');

        // 5. 获取 UniswapV2Pair 合约的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 6. 构造 salt = keccak256(token0, token1)，确保相同输入可复现同一地址
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // 7. 使用 CREATE2 部署合约，按以下参数：
        //    value = 0：不附带 ETH
        //    bytecode offset = add(bytecode, 32)：跳过内存中的长度前缀，指向真正的代码起点
        //    bytecode size   = mload(bytecode)：读取内存中 bytecode 的长度
        //    salt            = salt：部署盐值，保证地址可预测
        assembly {
            pair := create2(
                0,                // 不发送 ETH
                add(bytecode, 32),// 合约字节码实际起始位置
                mload(bytecode),  // 合约字节码长度
                salt              // 用于地址计算的盐值
            )
        }
        // 8. 调用新部署 Pair 合约的 initialize，将 token0、token1 写入
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 9. 在双向映射中记录 Pair 地址
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        // 10. 把新 Pair 加入 allPairs 列表
        allPairs.push(pair);
        // 11. 触发事件，外部监听
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @notice 设置手续费接收地址，只有 feeToSetter 能调用
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /// @notice 设置新的 feeToSetter，只有当前 feeToSetter 能调用
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
