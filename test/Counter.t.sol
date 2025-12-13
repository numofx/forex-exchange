// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {Counter} from "../src/Counter.sol";

/**
 * @title CounterTest
 * @notice Comprehensive test suite for Counter hook with dynamic fee overrides
 *
 * CRITICAL V4 SEMANTICS:
 * ======================
 * Fee overrides returned by beforeSwap are ONLY honored for DYNAMIC-FEE pools.
 * - Dynamic-fee pools: initialized with LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)
 * - Static-fee pools: initialized with a fixed fee (e.g., 3000 = 0.30%)
 *
 * For dynamic-fee pools, the hook must return fee | OVERRIDE_FEE_FLAG (0x400000)
 * to signal that the returned fee should override the pool's stored fee.
 *
 * This test suite verifies:
 * 1. Hook plumbing (counters, storage, events, access control)
 * 2. Fee override behavior in DYNAMIC-FEE pools (swap output changes)
 * 3. Multi-pool independence
 */
contract CounterTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey dynamicFeePoolKey;   // Dynamic-fee pool where overrides work
    PoolKey staticFeePoolKey;    // Static-fee pool where overrides are ignored

    Counter hook;
    PoolId dynamicPoolId;
    PoolId staticPoolId;

    uint256 dynamicTokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // Deploys all required artifacts
        deployArtifacts();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("Counter.sol:Counter", constructorArgs, flags);
        hook = Counter(flags);

        // Create DYNAMIC-FEE pool (fee overrides will be honored)
        dynamicFeePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // 0x800000 signals dynamic fee
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        dynamicPoolId = dynamicFeePoolKey.toId();
        poolManager.initialize(dynamicFeePoolKey, Constants.SQRT_PRICE_1_1);

        // Create STATIC-FEE pool (fee overrides will be IGNORED)
        staticFeePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.30% static fee
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        staticPoolId = staticFeePoolKey.toId();
        poolManager.initialize(staticFeePoolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to both pools
        tickLower = TickMath.minUsableTick(60);
        tickUpper = TickMath.maxUsableTick(60);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // Add liquidity to dynamic-fee pool
        (dynamicTokenId,) = positionManager.mint(
            dynamicFeePoolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Add liquidity to static-fee pool
        positionManager.mint(
            staticFeePoolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ==================== Owner Access Control Tests ====================

    function test_setExtraFee_ownerOnly_revertsNotOwner() public {
        address nonOwner = address(0xBEEF);

        vm.prank(nonOwner);
        vm.expectRevert(Counter.NotOwner.selector);
        hook.setExtraFee(dynamicFeePoolKey, 5000);
    }

    // ==================== Event and Storage Tests ====================

    function test_setExtraFee_emitsEvent_andSetsStorage() public {
        uint24 newFee = 3000;

        vm.expectEmit(true, false, false, true, address(hook));
        emit Counter.ExtraFeeSet(dynamicPoolId, newFee);

        hook.setExtraFee(dynamicFeePoolKey, newFee);

        assertEq(hook.extraFee(dynamicPoolId), newFee, "extraFee storage not updated");
    }

    // ==================== Counter Tests ====================

    function test_beforeSwap_incrementsCounter_perPool() public {
        assertEq(hook.beforeSwapCount(dynamicPoolId), 0, "Initial beforeSwapCount should be 0");
        assertEq(hook.afterSwapCount(dynamicPoolId), 0, "Initial afterSwapCount should be 0");

        _performSwap(dynamicFeePoolKey, 1e18);

        assertEq(hook.beforeSwapCount(dynamicPoolId), 1, "beforeSwapCount should increment to 1");
        assertEq(hook.afterSwapCount(dynamicPoolId), 1, "afterSwapCount should increment to 1");

        _performSwap(dynamicFeePoolKey, 1e18);

        assertEq(hook.beforeSwapCount(dynamicPoolId), 2, "beforeSwapCount should increment to 2");
        assertEq(hook.afterSwapCount(dynamicPoolId), 2, "afterSwapCount should increment to 2");
    }

    function test_liquidityCounters_increment_perPool() public {
        // Setup created 1 position per pool
        assertEq(hook.beforeAddLiquidityCount(dynamicPoolId), 1, "Setup should have added liquidity once");
        assertEq(hook.beforeRemoveLiquidityCount(dynamicPoolId), 0, "No liquidity removed yet");

        // Remove some liquidity
        uint256 liquidityToRemove = 1e18;
        positionManager.decreaseLiquidity(
            dynamicTokenId,
            liquidityToRemove,
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        assertEq(hook.beforeAddLiquidityCount(dynamicPoolId), 1, "beforeAddLiquidityCount unchanged");
        assertEq(hook.beforeRemoveLiquidityCount(dynamicPoolId), 1, "beforeRemoveLiquidityCount should be 1");

        // Add more liquidity
        uint256 liquidityToAdd = 10e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToAdd)
        );

        positionManager.increaseLiquidity(
            dynamicTokenId,
            liquidityToAdd,
            amount0 + 1,
            amount1 + 1,
            block.timestamp,
            Constants.ZERO_BYTES
        );

        assertEq(hook.beforeAddLiquidityCount(dynamicPoolId), 2, "beforeAddLiquidityCount should be 2");
        assertEq(hook.beforeRemoveLiquidityCount(dynamicPoolId), 1, "beforeRemoveLiquidityCount unchanged");
    }

    // ==================== DYNAMIC-FEE Pool Tests ====================
    // These tests verify that fee overrides ACTUALLY WORK in dynamic-fee pools

    function test_dynamicFeePool_feeOverride_changesSwapOutput() public {
        uint256 swapAmount = 1e18;

        // Pool A: existing dynamic-fee pool from setUp (tickSpacing 60, extraFee default 0)
        PoolKey memory poolAKey = dynamicFeePoolKey;

        // Pool B: dynamic-fee pool with SAME currencies as Pool A but different tickSpacing to differentiate PoolKey
        PoolKey memory poolBKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(hook)
        });
        PoolId poolBId = poolBKey.toId();
        poolManager.initialize(poolBKey, Constants.SQRT_PRICE_1_1);

        // Provide identical liquidity amounts to Pool B using its tick spacing
        int24 bTickLower = TickMath.minUsableTick(poolBKey.tickSpacing);
        int24 bTickUpper = TickMath.maxUsableTick(poolBKey.tickSpacing);
        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(bTickLower),
            TickMath.getSqrtPriceAtTick(bTickUpper),
            liquidityAmount
        );
        positionManager.mint(
            poolBKey,
            bTickLower,
            bTickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Apply fee override only to Pool B
        hook.setExtraFee(poolBKey, 10000); // 1%

        // Perform identical swaps
        BalanceDelta deltaNoFee = _performSwap(poolAKey, swapAmount);
        BalanceDelta deltaWithFee = _performSwap(poolBKey, swapAmount);

        int128 amountOutNoFee = deltaNoFee.amount1();
        int128 amountOutWithFee = deltaWithFee.amount1();

        assertTrue(amountOutNoFee > 0, "Pool A swap should produce output");
        assertTrue(amountOutWithFee > 0, "Pool B swap should produce output");
        assertLt(amountOutWithFee, amountOutNoFee, "Higher fee should reduce output");
        assertEq(hook.extraFee(poolBId), 10000, "Fee override should be stored for Pool B");
    }

    // ==================== Multi-Pool Independence Tests ====================

    function test_multiPool_independence() public {
        // Set different fees for dynamic and static pools
        uint24 dynamicFee = 2000;
        uint24 staticFee = 8000;

        hook.setExtraFee(dynamicFeePoolKey, dynamicFee);
        hook.setExtraFee(staticFeePoolKey, staticFee);

        // Verify fees are independent
        assertEq(hook.extraFee(dynamicPoolId), dynamicFee, "Dynamic pool fee incorrect");
        assertEq(hook.extraFee(staticPoolId), staticFee, "Static pool fee incorrect");

        // Perform swaps on both pools
        _performSwap(dynamicFeePoolKey, 1e18);
        _performSwap(staticFeePoolKey, 1e18);

        // Verify counters are independent
        assertEq(hook.beforeSwapCount(dynamicPoolId), 1, "Dynamic pool beforeSwapCount should be 1");
        assertEq(hook.afterSwapCount(dynamicPoolId), 1, "Dynamic pool afterSwapCount should be 1");

        assertEq(hook.beforeSwapCount(staticPoolId), 1, "Static pool beforeSwapCount should be 1");
        assertEq(hook.afterSwapCount(staticPoolId), 1, "Static pool afterSwapCount should be 1");

        // Verify liquidity counters are independent
        assertEq(hook.beforeAddLiquidityCount(dynamicPoolId), 1, "Dynamic pool should have 1 liquidity add");
        assertEq(hook.beforeAddLiquidityCount(staticPoolId), 1, "Static pool should have 1 liquidity add");

        // Perform another swap on dynamic pool only
        _performSwap(dynamicFeePoolKey, 1e18);

        // Dynamic pool counter increases
        assertEq(hook.beforeSwapCount(dynamicPoolId), 2, "Dynamic pool beforeSwapCount should be 2");

        // Static pool counter unchanged
        assertEq(hook.beforeSwapCount(staticPoolId), 1, "Static pool beforeSwapCount should still be 1");
    }

    // ==================== Helper Functions ====================

    function _performSwap(PoolKey memory key, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

}
