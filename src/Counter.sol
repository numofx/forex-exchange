// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * TESTING INSTRUCTIONS
 * ====================
 *
 * This contract demonstrates a Uniswap v4 hook with per-pool LP fee overrides.
 * It maintains the original counter functionality while adding dynamic fee management.
 *
 * HOW TO TEST:
 *
 * 1. Deploy the Hook Contract:
 *    - Deploy Counter with the PoolManager address
 *    - The deployer becomes the owner (msg.sender)
 *
 * 2. Create a Pool with This Hook:
 *    - Use PoolManager.initialize() with a PoolKey that references this hook
 *    - Ensure the hook address has the correct flags/prefix for Uniswap v4
 *
 * 3. Test Fee Override Functionality:
 *    a) Initial State (extraFee = 0):
 *       - Perform a swap on the pool
 *       - Verify beforeSwapCount[poolId] increments
 *       - Verify the swap uses default pool LP fees (extraFee returns 0)
 *
 *    b) Set Fee Override:
 *       - As owner, call setExtraFee(poolKey, 3000) // 0.30% fee
 *       - Verify ExtraFeeSet event is emitted
 *       - Verify extraFee[poolId] returns 3000
 *
 *    c) Swap with Fee Override:
 *       - Perform another swap on the pool
 *       - Compare swap output/fees vs. the previous swap with extraFee=0
 *       - Verify beforeSwapCount[poolId] increments again
 *       - The hook should return the fee override (3000) in beforeSwap
 *
 * 4. Test Multi-Pool Independence:
 *    - Create a second pool with the same hook
 *    - Set different extraFee values for each pool
 *    - Verify each pool maintains independent:
 *      * extraFee values
 *      * beforeSwapCount / afterSwapCount counters
 *      * beforeAddLiquidityCount / beforeRemoveLiquidityCount counters
 *
 * 5. Test Access Control:
 *    - From a non-owner address, attempt setExtraFee()
 *    - Verify it reverts with NotOwner()
 *
 * 6. Test Liquidity Operations:
 *    - Add liquidity to the pool
 *    - Verify beforeAddLiquidityCount[poolId] increments
 *    - Remove liquidity from the pool
 *    - Verify beforeRemoveLiquidityCount[poolId] increments
 *
 * FUTURE ENHANCEMENTS:
 * - Implement custom pricing curves based on the fee override
 * - Add dynamic fee adjustment based on volatility or other metrics
 * - Enable beforeSwapReturnDelta for liquidity provision in the hook
 */

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
 * @notice A Uniswap v4 hook template for testing hook plumbing and per-pool fee overrides.
 * @dev This contract demonstrates how to implement a custom LP fee override in beforeSwap.
 *      It maintains the original counter functionality while adding fee override capability.
 *      Future versions will implement custom pricing curves based on these fee overrides.
 */
contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;

    // -----------------------------------------------
    // Custom Errors
    // -----------------------------------------------

    error NotOwner();

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    /// @notice Owner address with permission to set fee overrides
    address public owner;

    /// @notice Per-pool extra LP fee override (in hundredths of a bip, e.g., 3000 = 0.30%)
    /// @dev This fee is returned in beforeSwap to override the pool's default LP fee
    mapping(PoolId => uint24) public extraFee;

    // Original counter mappings from template
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
