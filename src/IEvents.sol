// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IEvents {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        int24 tickSpacing,
        address pool
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    event Sync(uint112 reserve0, uint112 reserve1);
}
