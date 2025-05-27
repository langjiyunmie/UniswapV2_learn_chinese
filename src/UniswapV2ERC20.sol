// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "./interfaces/IUniswapV2ERC20.sol";
import "./libraries/SafeMath.sol";

/// @title 统一的 ERC20 & Permit 基类
/// @notice 本合约实现了标准 ERC20 功能外，还支持 EIP-2612 permit 签名授权，供 Uniswap V2 Pair 使用
contract UniswapV2ERC20 {
    using SafeMath for uint; // 引入 SafeMath 库，增强 uint 的安全加减乘除

    // —— ERC20 元数据 ——
    string public constant name = "Uniswap V2"; // 代币名称
    string public constant symbol = "UNI-V2"; // 代币符号
    uint8 public constant decimals = 18; // 小数位数，与 ETH 保持一致

    // —— ERC20 存储变量 ——
    uint public totalSupply; // 代币总发行量
    mapping(address => uint) public balanceOf; // 每个地址的余额
    mapping(address => mapping(address => uint)) public allowance; // 授权额度

    // —— Permit (EIP-2612) 支持 ——
    bytes32 public DOMAIN_SEPARATOR; // EIP712 域分隔符，用于签名校验
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces; // 每个地址的签名计数器，防止重放

    // —— 事件 ——
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    /// @notice 构造时计算并存储 EIP712 的 DOMAIN_SEPARATOR
    constructor() {
        uint chainId;
        // 通过 assembly 获取当前链的 chainId
        assembly {
            chainId := chainid()
        }
        // DOMAIN_SEPARATOR = keccak256(abi.encode(
        //    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        //    keccak256(bytes(name)),
        //    keccak256(bytes("1")),
        //    chainId,
        //    address(this)
        // ))
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)), // 代币名称
                keccak256(bytes("1")), // 版本号 "1"
                chainId, // 链 ID
                address(this) // 合约地址
            )
        );
    }

    /// @dev 内部铸币函数，增加 to 地址余额并更新总供应量
    /// @param to    接收铸造代币的地址
    /// @param value 铸造数量
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value); // 总供应量增加
        balanceOf[to] = balanceOf[to].add(value); // to 地址余额增加
        emit Transfer(address(0), to, value); // 触发 Transfer 事件 (from 0 表示铸造)
    }

    /// @dev 内部销毁函数，减少 from 地址余额并减少总供应量
    /// @param from  销毁代币的地址
    /// @param value 销毁数量
    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value); // from 地址余额减少
        totalSupply = totalSupply.sub(value); // 总供应量减少
        emit Transfer(from, address(0), value); // 触发 Transfer 事件 (to 0 表示销毁)
    }

    /// @dev 内部授权函数，设置 owner 授权给 spender 的额度
    /// @param owner   授权者地址
    /// @param spender 被授权使用币的地址
    /// @param value   授权额度
    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value; // 设置额度
        emit Approval(owner, spender, value); // 触发 Approval 事件
    }

    /// @dev 内部转账函数，不做安全检查，直接执行余额更新
    /// @param from  转出地址
    /// @param to    转入地址
    /// @param value 转账数量
    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value); // from 地址余额减少
        balanceOf[to] = balanceOf[to].add(value); // to 地址余额增加
        emit Transfer(from, to, value); // 触发 Transfer 事件
    }

    /// @notice ERC20 标准：授权 spender 花费 caller 的 value 代币
    /// @param spender 被授权地址
    /// @param value   授权数量
    /// @return 成功返回 true
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value); // 调用内部授权
        return true;
    }

    /// @notice ERC20 标准：将 caller 的 value 代币转给 to
    /// @param to    接收地址
    /// @param value 转账数量
    /// @return 成功返回 true
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value); // 调用内部转账
        return true;
    }

    /// @notice ERC20 标准：spender 从 from 转账 value 代币到 to，需先有授权
    /// @param from  转出地址
    /// @param to    转入地址
    /// @param value 转账数量
    /// @return 成功返回 true
    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool) {
        // 如果 allowance 不是最大值，则消耗授权额度
        if (allowance[from][msg.sender] != type(uint).max) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(
                value
            );
        }
        _transfer(from, to, value); // 执行余额变更
        return true;
    }

    /// @notice EIP-2612 Permit：通过签名授权，无需 on-chain 调用 approve
    /// @param owner    持有者地址
    /// @param spender  被授权地址
    /// @param value    授权数量
    /// @param deadline 签名过期时间戳
    /// @param v,r,s    ECDSA 签名参数
    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "UniswapV2: EXPIRED"); // 签名是否未过期

        // 构建 EIP712 Digest: "\x19\x01" || DOMAIN_SEPARATOR || keccak256(PERMIT数据)
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++, // 使用后递增 nonce
                        deadline
                    )
                )
            )
        );

        // 用 ECDSA 恢复签名者地址
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "UniswapV2: INVALID_SIGNATURE"
        );

        // 签名合法，则设置授权
        _approve(owner, spender, value);
    }
}
