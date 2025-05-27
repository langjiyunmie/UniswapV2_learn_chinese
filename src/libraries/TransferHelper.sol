// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

// 辅助库：与 ERC20 代币交互及发送 ETH 时，保证在不一致返回值的情况下依然安全
library TransferHelper {
    // 安全调用 ERC20 approve 函数
    function safeApprove(address token, address to, uint256 value) internal {
        // 构造 approve(selector=0x095ea7b3, to, value) 的 calldata 并发起低级调用
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        // 要求调用成功，且要么没有返回数据，要么返回的数据解码为 true
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: APPROVE_FAILED");
    }

    // 安全调用 ERC20 transfer 函数
    function safeTransfer(address token, address to, uint256 value) internal {
        // 构造 transfer(selector=0xa9059cbb, to, value) 的 calldata 并发起低级调用
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        // 要求调用成功，且要么没有返回数据，要么返回的数据解码为 true
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FAILED");
    }

    // 安全调用 ERC20 transferFrom 函数
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        // 构造 transferFrom(selector=0x23b872dd, from, to, value) 的 calldata 并发起低级调用
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        // 要求调用成功，且要么没有返回数据，要么返回的数据解码为 true
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FROM_FAILED");
    }

    // 安全发送 ETH（原生币）
    function safeTransferETH(address to, uint256 value) internal {
        // 使用 .call 发送指定数量 ETH，不附加任何数据
        (bool success,) = to.call{value: value}(new bytes(0));
        // 要求发送成功
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }
}
