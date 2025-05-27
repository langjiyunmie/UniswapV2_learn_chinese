// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

// 处理二进制定点数运算的库（参考：https://en.wikipedia.org/wiki/Q_(number_format)）
library FixedPoint {
    // 定义一个 112.112 位的定点数结构：总共 224 位，整数部分 112 位，小数部分 112 位
    struct uq112x112 {
        uint224 _x;
    }

    // 定义一个 144.112 位的定点数结构：总共 256 位，整数部分 144 位，小数部分 112 位
    struct uq144x112 {
        uint256 _x;
    }

    // 小数部分的位数常量：112
    uint8 private constant RESOLUTION = 112;

    /// @notice 将 uint112 类型的整数编码为 UQ112x112 定点数
    /// @param x 原始整数
    /// @return 定点数表示（小数部分全为 0）
    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        // 将 x 左移 112 位，相当于 x * 2^112
        return uq112x112(uint224(x) << RESOLUTION);
    }

    /// @notice 将 uint144 类型的整数编码为 UQ144x112 定点数
    /// @param x 原始整数
    /// @return 定点数表示（小数部分全为 0）
    function encode144(uint144 x) internal pure returns (uq144x112 memory) {
        // 将 x 左移 112 位，相当于 x * 2^112
        return uq144x112(uint256(x) << RESOLUTION);
    }

    /// @notice 将一个 UQ112x112 定点数除以 uint112 整数，返回 UQ112x112
    /// @param self 被除的定点数
    /// @param x 除数
    /// @return 商；保留 112 位小数
    function div(uq112x112 memory self, uint112 x) internal pure returns (uq112x112 memory) {
        // 除数不能为零
        require(x != 0, "FixedPoint: DIV_BY_ZERO");
        // 直接用定点数内部整数除以 x
        return uq112x112(self._x / uint224(x));
    }

    /// @notice 将一个 UQ112x112 定点数乘以 uint 整数，返回 UQ144x112
    /// @param self 被乘的定点数
    /// @param y 乘数
    /// @return 结果定点数，保留 112 位小数；溢出时 revert
    function mul(uq112x112 memory self, uint256 y) internal pure returns (uq144x112 memory) {
        uint256 z;
        // 检查乘法是否溢出：y 为 0 或 (self._x * y) / y == self._x
        require(y == 0 || (z = uint256(self._x) * y) / y == uint256(self._x), "FixedPoint: MULTIPLICATION_OVERFLOW");
        // 返回新的定点数结构
        return uq144x112(z);
    }

    /// @notice 根据分子和分母直接构造一个 UQ112x112 定点数（分数）
    /// @param numerator 分子，uint112
    /// @param denominator 分母，uint112
    /// @return 分数对应的定点数表示
    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        // 分母必须大于 0
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        // 分子左移 112 位后除以分母，得到保留 112 位小数的定点数
        return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
    }

    /// @notice 将 UQ112x112 解码为 uint112（截断小数部分）
    /// @param self 定点数
    /// @return 只保留整数部分
    function decode(uq112x112 memory self) internal pure returns (uint112) {
        // 右移 112 位，相当于向下取整
        return uint112(self._x >> RESOLUTION);
    }

    /// @notice 将 UQ144x112 解码为 uint144（截断小数部分）
    /// @param self 定点数
    /// @return 只保留整数部分
    function decode144(uq144x112 memory self) internal pure returns (uint144) {
        // 右移 112 位，相当于向下取整
        return uint144(self._x >> RESOLUTION);
    }
}
