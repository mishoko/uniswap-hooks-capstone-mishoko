// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {VPINMath} from "./libraries/VPINMath.sol";

/// @title VPIN Dynamic Fee Hook
/// @notice Dynamically adjusts swap fees based on the VPIN (Volume-synchronized Probability
/// of Informed Trading) metric, incorporating Nezlobin-style directional fee asymmetry.
/// @dev First on-chain implementation of VPIN (Easley, Lopez de Prado, O'Hara 2012).
/// High VPIN = toxic order flow = higher fees to protect LPs.
/// Low VPIN = organic flow = lower fees to attract volume.
contract VPINDynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // --- Errors ---
    error MustUseDynamicFee();
    error InvalidBucketSize();
    error InvalidFeeRange();

    // --- Configuration (immutable per deployment) ---
    uint256 public immutable BUCKET_SIZE;
    uint24 public immutable BASE_FEE;
    uint24 public immutable MAX_FEE;

    // --- Per-pool state ---
    mapping(PoolId => VPINMath.VPINState) internal _vpinStates;
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => uint256) public lastBlockNumbers;

    constructor(
        IPoolManager _poolManager,
        uint256 _bucketSize,
        uint24 _baseFee,
        uint24 _maxFee
    ) BaseHook(_poolManager) {
        if (_bucketSize == 0) revert InvalidBucketSize();
        if (_maxFee < _baseFee) revert InvalidFeeRange();
        BUCKET_SIZE = _bucketSize;
        BASE_FEE = _baseFee;
        MAX_FEE = _maxFee;
    }

    // --- Hook Permissions ---

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
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

    // --- Hook Functions ---

    /// @notice Enforce that the pool uses dynamic fees
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Initialize VPIN state and tick tracking for a new pool
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        lastTicks[poolId] = tick;
        lastBlockNumbers[poolId] = block.number;
        // _vpinStates[poolId] is zero-initialized by default
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Calculate and return the dynamic fee based on VPIN + directional adjustment
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // 1. Get current VPIN (from last completed bucket cycle)
        uint256 vpin = _vpinStates[poolId].lastVPIN;

        // 2. Calculate base dynamic fee from VPIN
        //    fee = baseFee + (maxFee - baseFee) * vpin / WAD
        uint24 vpinFee = BASE_FEE + uint24(
            uint256(MAX_FEE - BASE_FEE) * vpin / 1e18
        );

        // 3. Apply Nezlobin directional adjustment based on per-block tick movement
        int24 tickDelta = 0;
        if (block.number > lastBlockNumbers[poolId]) {
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            tickDelta = currentTick - lastTicks[poolId];
        }

        uint24 finalFee = _applyDirectionalAdjustment(vpinFee, tickDelta, params.zeroForOne);

        // 4. Return with OVERRIDE_FEE_FLAG so this fee is used for the swap
        uint24 feeWithFlag = finalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /// @notice Update VPIN state and tick tracking after each swap
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // 1. Classify trade direction and extract ACTUAL executed volume
        //    Use BalanceDelta (not amountSpecified) to handle partial fills correctly.
        //    zeroForOne = true means selling token0 (classified as "sell")
        //    zeroForOne = false means buying token0 (classified as "buy")
        bool isBuy = !params.zeroForOne;

        // Extract the actual input volume from the delta
        // delta.amount0() and delta.amount1() are from the user's perspective:
        //   negative = user paid, positive = user received
        // We want the absolute value of the input token amount
        int128 inputAmount = params.zeroForOne ? delta.amount0() : delta.amount1();
        uint256 volume = inputAmount < 0 ? uint256(uint128(-inputAmount)) : uint256(uint128(inputAmount));

        // 2. Accumulate volume into VPIN buckets
        VPINMath.accumulate(_vpinStates[poolId], isBuy, volume, BUCKET_SIZE);

        // 3. Update tick tracking for the Nezlobin directional component (once per block)
        if (block.number > lastBlockNumbers[poolId]) {
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            lastTicks[poolId] = currentTick;
            lastBlockNumbers[poolId] = block.number;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // --- Internal Helpers ---

    /// @notice Apply Nezlobin-style directional fee asymmetry
    /// @dev Swaps aligned with recent price momentum pay higher fees (taxing arbitrageurs).
    ///      Swaps against momentum pay lower fees (attracting organic rebalancing flow).
    function _applyDirectionalAdjustment(
        uint24 fee,
        int24 tickDelta,
        bool zeroForOne
    ) internal pure returns (uint24) {
        if (tickDelta == 0) return fee;

        // tickDelta > 0: token0 price increased (buys dominated last block)
        // tickDelta < 0: token0 price decreased (sells dominated last block)
        // zeroForOne = true: this swap sells token0 (goes AGAINST upward momentum)
        // zeroForOne = false: this swap buys token0 (goes WITH upward momentum)
        bool swapAlignedWithMomentum = (tickDelta > 0 && !zeroForOne)
            || (tickDelta < 0 && zeroForOne);

        // Scale adjustment by |tickDelta| relative to a reference of 100 ticks
        uint256 absDelta = tickDelta > 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));
        uint24 adjustment = uint24((uint256(fee) * absDelta) / 10000);

        // Cap adjustment at 50% of the base fee to prevent extreme swings
        uint24 maxAdjustment = fee / 2;
        if (adjustment > maxAdjustment) {
            adjustment = maxAdjustment;
        }

        if (swapAlignedWithMomentum) {
            return fee + adjustment;
        } else {
            return fee > adjustment ? fee - adjustment : 1;
        }
    }

    // --- Public View Functions (VPIN Oracle) ---

    /// @notice Get the current VPIN value for a pool (WAD-scaled, 0 to 1e18)
    function getVPIN(PoolKey calldata key) external view returns (uint256) {
        return _vpinStates[key.toId()].lastVPIN;
    }

    /// @notice Get the estimated base fee for a pool (without directional adjustment)
    function getPoolFeeEstimate(PoolKey calldata key) external view returns (uint24) {
        uint256 vpin = _vpinStates[key.toId()].lastVPIN;
        return BASE_FEE + uint24(uint256(MAX_FEE - BASE_FEE) * vpin / 1e18);
    }

    /// @notice Get the number of filled VPIN buckets for a pool
    function getFilledBuckets(PoolKey calldata key) external view returns (uint256) {
        return _vpinStates[key.toId()].filledBuckets;
    }
}
