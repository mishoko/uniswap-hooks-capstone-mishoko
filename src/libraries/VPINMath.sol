// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title VPINMath
/// @notice Library for computing Volume-synchronized Probability of Informed Trading (VPIN)
/// @dev Based on Easley, Lopez de Prado, O'Hara (2012)
/// VPIN measures order flow toxicity by tracking buy/sell volume imbalance
/// in fixed-volume buckets (volume-time, not clock-time)
library VPINMath {
    uint256 constant NUM_BUCKETS = 50;
    uint256 constant WAD = 1e18;

    struct VPINState {
        uint256[NUM_BUCKETS] buyVolumes;
        uint256[NUM_BUCKETS] sellVolumes;
        uint256 currentBucketIdx;
        uint256 currentBucketBuyVol;
        uint256 currentBucketSellVol;
        uint256 currentBucketTotalVol;
        uint256 filledBuckets;
        uint256 lastVPIN; // WAD-scaled [0, 1e18]
    }

    /// @notice Accumulate trade volume into the current VPIN bucket
    /// @param state The VPIN state for the pool
    /// @param isBuy True if this trade is a "buy" (oneForZero)
    /// @param volume The absolute trade volume
    /// @param bucketSize Volume threshold per bucket
    function accumulate(
        VPINState storage state,
        bool isBuy,
        uint256 volume,
        uint256 bucketSize
    ) internal {
        uint256 remaining = volume;

        while (remaining > 0) {
            uint256 spaceInBucket = bucketSize - state.currentBucketTotalVol;

            if (remaining >= spaceInBucket) {
                // Fill the current bucket and rotate
                if (isBuy) {
                    state.currentBucketBuyVol += spaceInBucket;
                } else {
                    state.currentBucketSellVol += spaceInBucket;
                }
                remaining -= spaceInBucket;

                // Store completed bucket into circular buffer
                uint256 idx = state.currentBucketIdx;
                state.buyVolumes[idx] = state.currentBucketBuyVol;
                state.sellVolumes[idx] = state.currentBucketSellVol;

                // Advance to next bucket
                state.currentBucketIdx = (idx + 1) % NUM_BUCKETS;
                if (state.filledBuckets < NUM_BUCKETS) {
                    state.filledBuckets++;
                }

                // Reset current bucket accumulators
                state.currentBucketBuyVol = 0;
                state.currentBucketSellVol = 0;
                state.currentBucketTotalVol = 0;

                // Recompute VPIN after each bucket completion
                state.lastVPIN = _computeVPIN(state, bucketSize);
            } else {
                // Partially fill the current bucket
                if (isBuy) {
                    state.currentBucketBuyVol += remaining;
                } else {
                    state.currentBucketSellVol += remaining;
                }
                state.currentBucketTotalVol += remaining;
                remaining = 0;
            }
        }
    }

    /// @notice Compute VPIN from the circular buffer of completed buckets
    /// @dev VPIN = (1/N) * sum(|buyVol[i] - sellVol[i]|) / bucketSize
    /// @return vpin WAD-scaled VPIN value [0, 1e18]
    function _computeVPIN(
        VPINState storage state,
        uint256 bucketSize
    ) private view returns (uint256) {
        uint256 n = state.filledBuckets;
        if (n == 0) return 0;

        uint256 totalImbalance = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 buyVol = state.buyVolumes[i];
            uint256 sellVol = state.sellVolumes[i];
            if (buyVol > sellVol) {
                totalImbalance += buyVol - sellVol;
            } else {
                totalImbalance += sellVol - buyVol;
            }
        }

        // VPIN = totalImbalance / (n * bucketSize), scaled to WAD
        return (totalImbalance * WAD) / (n * bucketSize);
    }
}
