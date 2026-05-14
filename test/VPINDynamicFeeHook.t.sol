// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

import {VPINDynamicFeeHook} from "../src/VPINDynamicFeeHook.sol";

contract VPINDynamicFeeHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VPINDynamicFeeHook hook;

    uint256 constant BUCKET_SIZE = 1 ether;
    uint24 constant BASE_FEE = 3000;  // 0.3%
    uint24 constant MAX_FEE = 10000;  // 1%

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy and approve two test tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flag bits in the address
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
            )
        );
        deployCodeTo(
            "VPINDynamicFeeHook",
            abi.encode(manager, BUCKET_SIZE, BASE_FEE, MAX_FEE),
            hookAddress
        );
        hook = VPINDynamicFeeHook(hookAddress);

        // Initialize a pool with DYNAMIC_FEE_FLAG
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Add liquidity at multiple ranges
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // =========================================================================
    // Test 1: Pool without DYNAMIC_FEE_FLAG reverts
    // =========================================================================
    function test_rejectsNonDynamicFeePool() public {
        vm.expectRevert();
        initPool(
            currency0,
            currency1,
            hook,
            3000, // Fixed fee, not dynamic
            SQRT_PRICE_1_1
        );
    }

    // =========================================================================
    // Test 2: Fresh pool has VPIN = 0
    // =========================================================================
    function test_initialVPINIsZero() public view {
        uint256 vpin = hook.getVPIN(key);
        assertEq(vpin, 0, "Initial VPIN should be 0");

        uint24 fee = hook.getPoolFeeEstimate(key);
        assertEq(fee, BASE_FEE, "Initial fee should be BASE_FEE");
    }

    // =========================================================================
    // Test 3: Balanced flow keeps VPIN low
    // =========================================================================
    function test_balancedFlowKeepsLowVPIN() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Alternate buy/sell swaps to fill several buckets with balanced flow
        for (uint256 i = 0; i < 10; i++) {
            // Buy (oneForZero)
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings,
                ZERO_BYTES
            );

            // Sell (zeroForOne)
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpin = hook.getVPIN(key);
        console.log("Balanced flow VPIN:", vpin);

        // VPIN should be very low for balanced flow
        // Each bucket has ~equal buy and sell volume
        assertLt(vpin, 0.3e18, "VPIN should be low for balanced flow");
    }

    // =========================================================================
    // Test 4: Toxic (one-directional) flow raises VPIN
    // =========================================================================
    function test_toxicFlowRaisesVPIN() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // All swaps in the same direction (all buys) to simulate toxic flow
        for (uint256 i = 0; i < 10; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpin = hook.getVPIN(key);
        console.log("Toxic flow VPIN:", vpin);

        // VPIN should be high for one-directional flow
        assertGt(vpin, 0.8e18, "VPIN should be high for toxic flow");
    }

    // =========================================================================
    // Test 5: VPIN decays after toxic flow is followed by balanced flow
    // =========================================================================
    function test_vpinDecaysAfterBalancing() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Phase 1: Toxic flow (all sells)
        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpinAfterToxic = hook.getVPIN(key);
        console.log("VPIN after toxic phase:", vpinAfterToxic);

        // Phase 2: Balanced flow to bring VPIN back down
        for (uint256 i = 0; i < 20; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings,
                ZERO_BYTES
            );
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpinAfterBalanced = hook.getVPIN(key);
        console.log("VPIN after balanced phase:", vpinAfterBalanced);

        assertLt(vpinAfterBalanced, vpinAfterToxic, "VPIN should decrease after balanced flow");
    }

    // =========================================================================
    // Test 6: Directional fee asymmetry
    // =========================================================================
    function test_directionalFeeAsymmetry() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Do a large swap in one direction to create tick momentum
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ZERO_BYTES
        );

        // Move to next block so tick delta is picked up
        vm.roll(block.number + 1);

        // Now check: a swap in the SAME direction (momentum-aligned) should have higher output cost
        // A swap AGAINST momentum should have lower cost
        // We test by comparing output amounts for same input

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // Swap WITH momentum (buying more token0)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ZERO_BYTES
        );

        uint256 outputWithMomentum = currency0.balanceOfSelf() - balance0Before;

        // Reset for next swap
        balance0Before = currency0.balanceOfSelf();
        balance1Before = currency1.balanceOfSelf();

        // Swap AGAINST momentum (selling token0)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ZERO_BYTES
        );

        uint256 outputAgainstMomentum = currency1.balanceOfSelf() - balance1Before;

        console.log("Output with momentum:", outputWithMomentum);
        console.log("Output against momentum:", outputAgainstMomentum);

        // The swap against momentum should get better output (lower fee)
        // The swap with momentum should get worse output (higher fee)
        // Since pool is near 1:1 price, outputs should be comparable in magnitude
        // but the against-momentum trade should get more output per unit input
        assertGt(outputAgainstMomentum, outputWithMomentum,
            "Counter-momentum swaps should get better rates");
    }

    // =========================================================================
    // Test 7: Fee bounds are always respected
    // =========================================================================
    function test_feeBoundsRespected() public view {
        // At VPIN = 0, fee should be BASE_FEE
        uint24 feeAtZero = hook.getPoolFeeEstimate(key);
        assertGe(feeAtZero, BASE_FEE, "Fee should never go below BASE_FEE");
        assertLe(feeAtZero, MAX_FEE, "Fee should never exceed MAX_FEE");
    }

    // =========================================================================
    // Test 8: Bucket rotation works (circular buffer)
    // =========================================================================
    function test_bucketRotation() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Fill more than NUM_BUCKETS (50) by doing many swaps
        // Each bucket needs BUCKET_SIZE (1 ether) of volume
        // So we need > 50 ether of volume total
        for (uint256 i = 0; i < 60; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: i % 2 == 0
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 filledBuckets = hook.getFilledBuckets(key);
        // After 60 swaps of 0.5 ether each = 30 ether total volume
        // With bucket size of 1 ether, that's 30 buckets filled
        // filledBuckets should cap at NUM_BUCKETS (50)
        console.log("Filled buckets:", filledBuckets);
        assertLe(filledBuckets, 50, "Filled buckets should not exceed NUM_BUCKETS");
        assertGt(filledBuckets, 0, "Some buckets should be filled");

        // VPIN should still be computable and valid
        uint256 vpin = hook.getVPIN(key);
        assertLe(vpin, 1e18, "VPIN should never exceed 1e18");
    }

    // =========================================================================
    // Test 9: VPIN oracle view returns correct value
    // =========================================================================
    function test_vpinOracleView() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Do some toxic flow
        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpin = hook.getVPIN(key);
        uint24 feeEstimate = hook.getPoolFeeEstimate(key);

        // Fee estimate should match the VPIN-based calculation
        uint24 expectedFee = BASE_FEE + uint24(uint256(MAX_FEE - BASE_FEE) * vpin / 1e18);
        assertEq(feeEstimate, expectedFee, "Fee estimate should match VPIN calculation");

        console.log("Oracle VPIN:", vpin);
        console.log("Oracle fee estimate:", feeEstimate);
    }

    // =========================================================================
    // Test 10: Multiple pools have independent VPIN state
    // =========================================================================
    function test_multiplePoolsIndependent() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Create a second pool with different tick spacing
        (PoolKey memory key2,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            int24(10), // different tick spacing
            SQRT_PRICE_1_1
        );

        // Add liquidity to second pool
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Do toxic flow on pool 1 only
        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                testSettings,
                ZERO_BYTES
            );
        }

        uint256 vpinPool1 = hook.getVPIN(key);
        uint256 vpinPool2 = hook.getVPIN(key2);

        console.log("Pool 1 VPIN:", vpinPool1);
        console.log("Pool 2 VPIN:", vpinPool2);

        // Pool 2 should still have zero VPIN (no swaps there)
        assertEq(vpinPool2, 0, "Pool 2 VPIN should be 0");
        assertGt(vpinPool1, vpinPool2, "Pool 1 VPIN should be higher than Pool 2");
    }
}
