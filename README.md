# VPIN Dynamic Fee Hook

**Market Microstructure-Informed Fee Adjustment for Uniswap V4**

Implementation of the VPIN (Volume-synchronized Probability of Informed Trading) metric that dynamically adjusts swap fees based on detected order flow toxicity, incorporating Nezlobin-style directional fee asymmetry to protect LPs from adverse selection.

## Problem

Liquidity providers in AMMs face systematic losses from informed traders (toxic order flow). Research shows LPs on major Uniswap v3 pools lost ~$60M more than they earned in fees over the analyzed period (Nezlobin, 2022). Current dynamic fee hooks use simplistic volatility proxies (gas prices, historical vol) that can't distinguish between organic price movement and toxic informed flow.

## Solution proposed: VPIN

VPIN is a well-established metric from market microstructure theory (Easley, Lopez de Prado, O'Hara, 2012) that directly measures the probability of informed trading by analyzing order flow imbalance in volume-synchronized buckets.

**Key insight**: Unlike time-based metrics, VPIN synchronizes to trade volume. Information events happen in "volume time", not clock time. When order flow is dominated by one side (all buys or all sells), VPIN approaches 1 indicating high toxicity. When flow is balanced, VPIN approaches 0.

### How It Works

```
                    ┌─────────────────────────────────────────┐
                    │           VPIN Dynamic Fee Hook          │
                    ├─────────────────────────────────────────┤
                    │                                         │
  Swap ──────────►  │  1. Classify trade (buy/sell)           │
                    │  2. Accumulate into volume bucket       │
                    │  3. When bucket full → rotate buffer    │
                    │  4. Recompute VPIN from last N buckets  │
                    │  5. Fee = baseFee + (maxFee-baseFee)*VPIN│
                    │  6. Apply directional adjustment        │
                    │                                         │
                    │  High VPIN → High fees → LP protection  │
                    │  Low VPIN  → Low fees  → Volume growth  │
                    │                                         │
                    └─────────────────────────────────────────┘
```

### VPIN Formula

```
For N volume buckets, each of size V:

  VPIN = (1/N) * Σ |buyVol[i] - sellVol[i]| / V

  VPIN ∈ [0, 1]
    0 = perfectly balanced flow (organic trading)
    1 = completely one-sided flow (maximum toxicity)

  Dynamic Fee = baseFee + (maxFee - baseFee) * VPIN
```

### Trade Classification

In AMMs, trade direction is unambiguous (unlike TradFi where Bulk Volume Classification is needed):
- `zeroForOne = true` → selling token0 (classified as "sell")
- `zeroForOne = false` → buying token0 (classified as "buy")

### Directional Fee Asymmetry (Nezlobin)

On top of the VPIN-based fee, we apply Nezlobin-style directional adjustment:
- Swaps aligned with recent price momentum (likely arbitrage) pay **higher** fees
- Swaps against momentum (organic rebalancing) pay **lower** fees

This discourages toxic arbitrage flow while attracting healthy order flow that rebalances the pool.

## Architecture

```
src/
├── VPINDynamicFeeHook.sol          # Main hook contract
│   ├── beforeInitialize            # Enforce DYNAMIC_FEE_FLAG
│   ├── afterInitialize             # Init VPIN state + tick tracking
│   ├── beforeSwap                  # Compute & return dynamic fee
│   └── afterSwap                   # Update VPIN state
├── libraries/
│   └── VPINMath.sol                # VPIN calculation (circular buffer)
test/
├── VPINDynamicFeeHook.t.sol        # 10 comprehensive tests
script/
├── DeployVPINHook.s.sol            # Testnet deployment with HookMiner
```

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BUCKET_SIZE` | 10 ETH | Volume per VPIN bucket. Smaller = more responsive |
| `NUM_BUCKETS` | 50 | VPIN window size (hardcoded). More = smoother signal |
| `BASE_FEE` | 3000 (0.3%) | Fee floor when VPIN = 0 |
| `MAX_FEE` | 10000 (1.0%) | Fee ceiling when VPIN = 1 |

## VPIN Oracle

The hook exposes VPIN as public view functions, enabling other protocols to read the toxicity signal:

```solidity
// Get current VPIN for a pool (0 to 1e18)
uint256 vpin = hook.getVPIN(poolKey);

// Get estimated fee based on current VPIN
uint24 fee = hook.getPoolFeeEstimate(poolKey);
```

## Build & Test

```bash
forge install
forge build
forge test -vv
```

### Test Results

```
[PASS] test_rejectsNonDynamicFeePool
[PASS] test_initialVPINIsZero
[PASS] test_balancedFlowKeepsLowVPIN        (VPIN: 0)
[PASS] test_toxicFlowRaisesVPIN             (VPIN: 1e18)
[PASS] test_vpinDecaysAfterBalancing        (1e18 -> 0.09e18)
[PASS] test_directionalFeeAsymmetry         (counter-momentum gets better rates)
[PASS] test_feeBoundsRespected
[PASS] test_bucketRotation
[PASS] test_vpinOracleView
[PASS] test_multiplePoolsIndependent
```

## Deployment

```bash
# Deploy to Unichain Sepolia
forge script script/DeployVPINHook.s.sol --rpc-url <RPC_URL> --broadcast
```

## Academic References

- Easley, D., Lopez de Prado, M., O'Hara, M. (2012). "Flow Toxicity and Liquidity in a High-frequency World." *Review of Financial Studies*, 25(5), 1457-1493.
- Nezlobin, A. (2022). "Toxic Order Flow on Decentralized Exchanges: Problem and Solutions." Medium.
- Nezlobin, A. (2022). "Solving Order Flow Toxicity." Medium.

## License

MIT
