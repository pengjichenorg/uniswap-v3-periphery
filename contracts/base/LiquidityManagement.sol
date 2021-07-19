// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';

import '../libraries/PoolAddress.sol';
import '../libraries/CallbackValidation.sol';
import '../libraries/LiquidityAmounts.sol';

import './PeripheryPayments.sol';
import './PeripheryImmutableState.sol';

/// @title Liquidity management functions
/// @notice Internal functions for safely managing liquidity in Uniswap V3
abstract contract LiquidityManagement is IUniswapV3MintCallback, PeripheryImmutableState, PeripheryPayments {
    struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        if (amount0Owed > 0) pay(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) pay(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
    }

    // 添加流动性使用的参数

    struct AddLiquidityParams {
        address token0;             // token0
        address token1;             // token1
        uint24 fee;                 // 手续费
        address recipient;          // 用户地址
        int24 tickLower;            // 价格下边界
        int24 tickUpper;            // 价格上边界
        uint256 amount0Desired;     // token0期望添加额
        uint256 amount1Desired;     // token1期望添加额
        uint256 amount0Min;         // token0最低额
        uint256 amount1Min;         // token1最低额
    }

    // 添加流动性
    // 将传入的代表价格范围tick转化为对应的存储价格
    // 根据期望提供的token和价格范围, 计算出对应的流动性L
    // 调用pool.mint()对postion及对应的tick对象进行修改

    /// @notice Add liquidity to an initialized pool
    function addLiquidity(AddLiquidityParams memory params)
        internal
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            IUniswapV3Pool pool
        )
    {

        // 根据token0, token1和fee这3个信息计算出交易对地址

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // 由poolKey获取pool地址

        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // 计算流动性大小

        // compute the liquidity amount
        {
            // 获取价格， 价格保存在pool的slot中
            // factory.createPool()时还没有设置价格，之后会调用pool.initialize()设置价格

            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            // 计算下边界和上边界的价格, 价格表示为P的开方
            // 根据白皮书设计: 添加流动性需要制定价格上边界和价格下边界，即B(价格较高)点和A(价格较低)点
            // 两个价格边界在前端显示的是价格， 二在合约中，使用价格对应的tick表示
            // 根据tick计算开方并放大后表示的A和B两个点的价格，base price: 1.0001是固定值，已定义在库中
            // 价格较低点 A点: tickLower -> sqrtRatioAx96
            // 价格较高点 B点: tickUpper -> sqrtRatioBx96

            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            // 计算添加的流动性
            // 里面涉及到白皮书书中提供的流动性计算公式

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }

        // 铸币ERC721 token
        // 计算出流动性后, 调用pool.mint()进入核心代码区域

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');
    }
}
