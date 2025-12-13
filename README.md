# ForexSwap

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

## Overview

ForexSwap is a Uniswap v4 hook implementation of a [log normal](https://en.wikipedia.org/wiki/Log-normal_distribution) market maker. It's statistical curve makes liquidity provisioning more passive and capital efficient on frontier currency pairs such as USD/KES that experience periods of high volatilty.

## Quick Start

Clone and set up the project:

```sh
$ git clone https://github.com/robertleifke/forex-swap
$ cd forex-swap
$ bun install
$ forge build
```

## Deploy pools

```solidity
IPoolManager poolManager = 
ForexSwap forexSwapHook = new ForexSwap(poolManager);

PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: 0,
    tickSpacing: 0,
    hooks: IHooks(address(forexSwapHook))
});
forexSwapHook.initializePool(poolKey);

forexSwapHook.updateForexSwapParams(
    1.1e18,  // mu = 1.1 (10% mean premium)
    2.5e17,  // sigma = 0.25 (25% volatility)
    5e15     // swapFee = 0.5%
);
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

### Inverse Normal CDF Implementation

ForexSwap uses the Beasley-Springer-Moro algorithm for computing Φ⁻¹(u):

```solidity
function _improvedInverseNormalCDF(uint256 u) internal pure returns (int256) {
    // Bounded to [-6σ, +6σ] for numerical stability
}
```

### Newton-Raphson Iteration

For swap calculations, ForexSwap employs iterative solving:

```solidity
function _solveExactInputWithLiquidity(...) internal view returns (...) {
    // Initial guess using constant product
    // Newton-Raphson iteration to solve: Φ⁻¹(x'/L) + Φ⁻¹(y'/L) = k
    // Convergence threshold: 1e-6 in WAD precision
    // Maximum iterations: 50
}
```
## License

This project is licensed under a Business Source License - see the [LICENSE](LICENSE) file for details.
