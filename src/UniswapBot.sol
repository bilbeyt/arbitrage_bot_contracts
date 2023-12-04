// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./WETH9.sol";

contract UniswapBotV2 is Ownable, IFlashLoanRecipient {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    enum TradeType {
        V2,
        V3
    }
    address private constant VAULT_ADDRESS =
    0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO =
    1461446703485210103287273052203988822378723970342;
    WETH9 internal immutable weth9 =
    WETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    constructor() Ownable() {}

    receive() external payable {}

    struct QuoteParams {
        address[] pools;
        address[] quoters;
        uint amount;
        address tokenIn;
    }

    struct ReserveParams {
        address token0;
        address token1;
        address pool;
    }

    function quote(QuoteParams memory params) public returns (uint[] memory) {
        address token = params.tokenIn;
        uint[] memory amountOuts = new uint[](params.pools.length);
        for (uint i = 0; i < params.pools.length; i++) {
            if (params.quoters[i] == address(0)) {
                (token, params.amount) = getV2AmountOut(
                    params.pools[i],
                    token,
                    params.amount
                );
            } else {
                (token, params.amount) = getV3AmountOut(
                    params.pools[i],
                    params.quoters[i],
                    token,
                    params.amount
                );
            }
            amountOuts[i] = params.amount;
        }
        return amountOuts;
    }

    function multiQuote(
        QuoteParams[] calldata paramsList
    ) external returns (uint[][] memory) {
        uint[][] memory outs = new uint[][](paramsList.length);
        for (uint i = 0; i < paramsList.length; i++) {
            outs[i] = quote(paramsList[i]);
        }
        return outs;
    }

    function getReserves(
        ReserveParams calldata params
    ) public view returns (uint[] memory) {
        uint[] memory reserves = new uint[](2);
        uint reserve0 = IERC20(params.token0).balanceOf(params.pool);
        uint reserve1 = IERC20(params.token1).balanceOf(params.pool);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
        return reserves;
    }

    function multiGetReserves(
        ReserveParams[] calldata poolParams
    ) external view returns (uint[][] memory) {
        uint[][] memory reserves = new uint[][](poolParams.length);
        for (uint i = 0; i < poolParams.length; i++) {
            reserves[i] = getReserves(poolParams[i]);
        }
        return reserves;
    }

    function startArbitrage(
        address borrowTokenAddress,
        uint borrowAmount,
        address[] calldata pools,
        uint[] calldata types,
        uint[] calldata amountOuts,
        uint bribe
    ) external onlyOwner {
        bytes memory data = abi.encode(
            address(this),
            pools,
            types,
            amountOuts,
            bribe
        );
        IERC20[] memory assets = new IERC20[](1);
        uint[] memory amounts = new uint[](1);
        assets[0] = IERC20(borrowTokenAddress);
        amounts[0] = borrowAmount;
        IVault(VAULT_ADDRESS).flashLoan(this, assets, amounts, data);
    }

    function getV2AmountOut(
        address poolAddress,
        address token,
        uint amountIn
    ) internal view returns (address, uint) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        (address tokenOut, uint112 reserveIn, uint112 reserveOut) = token ==
        pair.token0()
            ? (pair.token1(), reserve0, reserve1)
            : (pair.token0(), reserve1, reserve0);
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        uint amountOut = numerator / denominator;
        return (tokenOut, amountOut);
    }

    function getV3AmountOut(
        address poolAddress,
        address quoterAddress,
        address tokenIn,
        uint amountIn
    ) internal returns (address, uint) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        address tokenOut = pool.token0() == tokenIn
            ? pool.token1()
            : pool.token0();
        IQuoterV2 quoter = IQuoterV2(quoterAddress);
        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2
            .QuoteExactInputSingleParams(
            tokenIn,
            tokenOut,
            amountIn,
            pool.fee(),
            0
        );
        (uint amountOut, , , ) = quoter.quoteExactInputSingle(params);
        return (tokenOut, amountOut);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address poolAddress, address tokenIn) = abi.decode(
            data,
            (address, address)
        );
        require(msg.sender == poolAddress, "caller should be pool");
        int256 amountToPay = amount0Delta > 0 ? amount0Delta : amount1Delta;
        IERC20(tokenIn).safeTransfer(poolAddress, uint(amountToPay));
    }

    function makeV2Trade(
        address poolAddress,
        address tokenIn,
        uint amountIn,
        uint amountOut
    ) internal returns (address, uint) {
        IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
        address tokenOut = pair.token0() == tokenIn
            ? pair.token1()
            : pair.token0();
        uint amount0Out = pair.token0() == tokenOut ? amountOut : 0;
        uint amount1Out = pair.token1() == tokenOut ? amountOut : 0;
        IERC20(tokenIn).safeTransfer(poolAddress, amountIn);
        try
        pair.swap(amount0Out, amount1Out, address(this), bytes(""))
        {} catch (bytes memory) {
            revert(
                string.concat(
                "Execution reverted: ",
                Strings.toHexString(poolAddress)
            )
            );
        }
        return (tokenOut, amountOut);
    }

    function makeV3Trade(
        address poolAddress,
        address tokenIn,
        uint amountIn
    ) internal returns (address, uint) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        bool zeroForOne = pool.token0() == tokenIn ? true : false;
        bytes memory data = abi.encode(poolAddress, tokenIn);
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? MIN_SQRT_RATIO + 1
            : MAX_SQRT_RATIO - 1;
        (int256 amount0, int amount1) = (0, 0);
        try
        pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimitX96,
            data
        )
        returns (int firstAmount, int secondAmount) {
            amount0 = firstAmount;
            amount1 = secondAmount;
        } catch (bytes memory) {
            revert(
                string.concat(
                "Execution reverted: ",
                Strings.toHexString(poolAddress)
            )
            );
        }
        address tokenOut = zeroForOne ? pool.token1() : pool.token0();
        return (tokenOut, uint(-(zeroForOne ? amount1 : amount0)));
    }

    function makeTrades(
        address[] memory pools,
        uint[] memory types,
        address tokenIn,
        uint amount,
        uint[] memory amountOuts
    ) internal returns (uint) {
        address token = tokenIn;
        for (uint i = 0; i < pools.length; i++) {
            if (types[i] == uint(TradeType.V2)) {
                (token, amount) = makeV2Trade(
                    pools[i],
                    token,
                    amount,
                    amountOuts[i]
                );
            } else {
                (token, amount) = makeV3Trade(pools[i], token, amount);
            }
        }
        return amount;
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint[] memory amounts,
        uint[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == VAULT_ADDRESS, "caller should be vault");
        (
            address _sender,
            address[] memory pools,
            uint[] memory types,
            uint[] memory amountOuts,
            uint bribe
        ) = abi.decode(userData, (address, address[], uint[], uint[], uint));
        require(_sender == address(this), "address should be bot contract");
        uint payment = amounts[0] + feeAmounts[0];
        uint amountOut = makeTrades(
            pools,
            types,
            address(tokens[0]),
            amounts[0],
            amountOuts
        );
        require(amountOut > payment, "not profitable");
        tokens[0].safeTransfer(VAULT_ADDRESS, payment);
        (, uint profit) = amountOut.trySub(payment);
        if (address(tokens[0]) == address(weth9)) {
            (, uint profitMinusbribe) = profit.trySub(bribe);
            weth9.withdraw(profit);
            (bool sent, ) = payable(owner()).call{value: profitMinusbribe}("");
            require(sent, "can not send eth");
        } else {
            tokens[0].safeTransfer(owner(), profit);
        }
        if (bribe > 0) {
            (bool sent, ) = payable(block.coinbase).call{value: bribe}("");
            require(sent, "can not send eth to miner");
        }
    }
}
