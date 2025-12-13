# ForexSwap

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

## Overview

ForexSwap is an automated market maker for FX that is optimized for cross border payments. 

It uses a peicewise [log normal](https://en.wikipedia.org/wiki/Log-normal_distribution) curve to provide always-on, passive liquidity even when prices moves rapidly. This is in contrast to Uniswap V3, which relies on active management to maintain depth during volatility. Therefore, unreliable for payments. ForexSwap is implemented as a Uniswap V4 [custom curve](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/base/BaseCustomCurve.sol) hook to leverage the existing Uniswap routing and settlement infrastructure.

## Quick Start

Clone and set up the project:

```sh
$ git clone https://github.com/robertleifke/forex-swap
$ cd forex-swap
$ bun install
$ forge build
```

## Deploy pools

```Solidity
IPoolManager poolManager = /* deployed PoolManager */;
ForexSwap forexSwapHook = new ForexSwap(poolManager);

PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: 0,
    tickSpacing: 1, // must be nonzero
    hooks: IHooks(address(forexSwapHook))
});

forexSwapHook.initializePool(poolKey);

// Example: USD/KES ~130
forexSwapHook.updateForexSwapParams({
    muWad: 4867534450000000000, // ln(130)
    sigmaWad: 1e17,             // 10% log-vol
    swapFeeWad: 5e15,           // 0.5%
    pMinWad: 80e18,
    pMaxWad: 200e18,
    numBins: 512
});
```

## Testing

Run comprehensive tests for the ForexSwap implementation:

```sh
# Run all tests
$ forge test

# Run with detailed output
$ forge test -vvv

# Run gas reporting
$ forge test --gas-report

# Run specific ForexSwap tests
$ forge test --match-contract ForexSwap -vv
```


## Routing

### Piecewise Log-Normal Curve

ForexSwap implements a log-normal liquidity profile using a **precomputed, monotone lookup table** over log-price \( z = \ln p \) within a bounded price range \([p_{\min}, p_{\max}]\).

The log-price domain is discretized into \(N\) uniform bins:

\[
z_i = z_{\min} + i \cdot \Delta z,
\qquad
\Delta z = \frac{z_{\max} - z_{\min}}{N}
\]

For each bin boundary, the cumulative inventory is precomputed:

\[
X_i = L \cdot \Phi\!\left(\frac{z_i - \mu}{\sigma}\right)
\]

where:
- \( \Phi \) is the standard normal CDF,
- \( L \) is the total liquidity capacity,
- \( \mu \) and \( \sigma \) parameterize the log-normal distribution.

Only the table values \(X_i\) (and implicitly \(z_i\)) are stored onchain in fixed-point form.

---

### Swap Computation

All swaps are evaluated using **bounded, deterministic execution** with no iterative root-finding.

For a given current inventory \(x\):

1. **Locate the active bin**  
   Perform a binary search to find index \(i\) such that:
   \[
   X_i \le x < X_{i+1}
   \]

2. **Interpolate price within the bin**  
   Compute the interpolation factor:
   \[
   \lambda = \frac{x - X_i}{X_{i+1} - X_i}
   \]

   Recover log-price and price:
   \[
   z = z_i + \lambda \cdot \Delta z,
   \qquad
   p = e^z
   \]

3. **Execute the swap**  
   - Small swaps use the local marginal price.
   - Larger swaps advance across bins and accumulate cost piecewise using closed-form integration.

This approach guarantees predictable gas usage and avoids numerical instability or non-convergence.

---

### Exact-In and Exact-Out Swaps

- **Exact-in:** given an input amount, inventory is advanced forward across bins until the input is exhausted, accumulating output per bin.
- **Exact-out:** given a target output amount, the required input is computed by integrating price over inventory between the start and end positions.

Within each bin, pricing is linear in log-price, allowing exact closed-form evaluation.

---

### Tail Policy (Always-On Quotes)

ForexSwap supports continuous quoting through price extremes by defining explicit tail behavior outside the table range:

- **Soft tails:**  
  Beyond \([p_{\min}, p_{\max}]\), log-price increases with a steepening rule, ensuring quotes are always available but become increasingly punitive.

- **Hard bounds:**  
  Trades that would push the pool outside the supported range revert.

The tail policy is a deliberate risk-management choice and part of the pool configuration.

---

### Design Rationale

This piecewise log-normal implementation:
- encodes the liquidity profile directly in the pool,
- removes the need for active LP range management,
- guarantees always-on quotes when configured with soft tails,
- uses deterministic, bounded-gas execution suitable for a Uniswap V4 custom-curve hook.

The only approximation introduced is the discretization of the log-price domain; swap execution within each bin is exact.
