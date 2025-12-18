// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @title Counter Hook with LP Fee Override
 * @notice A Uniswap v4 hook with per-pool fee overrides.
 * @dev Demonstrates custom LP fee override in beforeSwap while maintaining the original counter functionality.
 */
contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;

    error NotOwner();

    /// @notice Owner address with permission to set fee overrides
    address public owner;

    /// @notice Per-pool extra LP fee override (in hundredths of a bip, e.g., 3000 = 0.30%)
    /// @dev This fee is returned in beforeSwap to override the pool's default LP fee
    mapping(PoolId => uint24) public extraFee;

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
    mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;

    // -----------------------------------------------
    // Events
    // -----------------------------------------------

    /// @notice Emitted when the extra fee for a pool is updated
    /// @param poolId The pool identifier
    /// @param extraFee The new extra fee (in hundredths of a bip)
    event ExtraFeeSet(PoolId indexed poolId, uint24 extraFee);

    // -----------------------------------------------
    // Constructor
    // -----------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // Owner Functions
    // -----------------------------------------------

    /// @notice Set the extra LP fee override for a specific pool (owner only)
    /// @param key The pool key identifying the pool
    /// @param newExtraFee The new extra fee in hundredths of a bip (e.g., 3000 = 0.30%)
    /// @dev Only the owner can call this function. The fee override is returned in beforeSwap.
    function setExtraFee(PoolKey calldata key, uint24 newExtraFee) external {
        if (msg.sender != owner) revert NotOwner();

        PoolId id = key.toId();
        extraFee[id] = newExtraFee;

        emit ExtraFeeSet(id, newExtraFee);
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    /// @notice Hook called before each swap
    /// @dev Increments the swap counter and returns the per-pool fee override.
    ///      Note: We return ZERO_DELTA (no liquidity delta) but provide the fee override.
    ///      The fee override allows testing hook plumbing without implementing pricing curves yet.
    ///
    ///      IMPORTANT: Fee overrides are ONLY honored for dynamic-fee pools (pools initialized with
    ///      LPFeeLibrary.DYNAMIC_FEE_FLAG). For static-fee pools, the returned fee is ignored.
    ///
    ///      The returned fee must have the OVERRIDE_FEE_FLAG (0x400000) set to signal to the pool
    ///      that the fee should be overridden for this swap.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        beforeSwapCount[id]++;

        uint24 fee = extraFee[id];

        // If a fee override is set, return it with the OVERRIDE_FEE_FLAG
        // This signals to dynamic-fee pools to use this fee instead of the stored fee
        if (fee > 0) {
            fee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        } else {
            // Return 0 to signal "no override" when fee not set
            fee = 0;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        beforeAddLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        beforeRemoveLiquidityCount[key.toId()]++;
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
