// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "v2-core/interfaces/IUniswapV2Pair.sol";
import "v2-core/interfaces/IUniswapV2Factory.sol";
import "v2-periphery/interfaces/IUniswapV2Router02.sol";

contract UniswapV2BotContract is Ownable, Pausable {
    using SafeERC20 for IERC20;

    address private constant FACTORY_ADDRESS =
        0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant ROUTER_ADDRESS =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    uint256 private deadline = block.timestamp + 1 days;
    uint256 private constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    constructor() Ownable(msg.sender) {}

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function fundContract(
        address _token,
        uint256 _amount
    ) public payable onlyOwner {
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
    }

    function withdrawToken(address _token, uint256 _amount) public onlyOwner {
        IERC20(_token).transferFrom(address(this), msg.sender, _amount);
    }

    function withdrawETH(uint256 _amount) public onlyOwner {
        bool sent = payable(msg.sender).send(_amount);
        require(sent, "Failed to send Ether");
    }

    function placeTrade(
        address _fromToken,
        address _toToken,
        uint256 _amountIn
    ) private returns (uint256) {
        address pair = IUniswapV2Factory(FACTORY_ADDRESS).getPair(
            _fromToken,
            _toToken
        );
        require(pair != address(0), "pool does not exist");
        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        uint256 amountRequired = IUniswapV2Router02(ROUTER_ADDRESS)
            .getAmountsOut(_amountIn, path)[1];

        uint256 amountReceived = IUniswapV2Router02(ROUTER_ADDRESS)
            .swapExactTokensForTokens(
                _amountIn,
                amountRequired,
                path,
                address(this),
                deadline
            )[1];

        require(amountReceived > 0, "Aborted tx: Trade returned zero");
        return amountReceived;
    }

    function uniswapV2Call(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _data
    ) external {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();

        address pair = IUniswapV2Factory(FACTORY_ADDRESS).getPair(
            token0,
            token1
        );
        require(msg.sender == pair, "the sender needs to match pair contract");
        require(
            _sender == address(this),
            "the sender should match this contract"
        );

        (address[] memory path, uint256 amount) = abi.decode(
            _data,
            (address[], uint256)
        );

        uint256 fee = ((amount * 3) / 997) + 1;
        uint256 amountToRepay = amount + fee;

        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;

        uint256 trade1AcquiredCoin = placeTrade(path[0], path[1], loanAmount);
        uint256 trade2AcquiredCoin = placeTrade(
            path[1],
            path[2],
            trade1AcquiredCoin
        );
        uint256 trade3AcquiredCoin = placeTrade(
            path[2],
            path[3],
            trade2AcquiredCoin
        );

        require(trade3AcquiredCoin > loanAmount, "not profitable");

        IERC20(path[0]).transfer(pair, amountToRepay);
    }

    function startArbitrage(
        address[] calldata path,
        address swapPairAddress,
        uint256 _amount
    ) external whenNotPaused {
        IERC20(path[0]).safeIncreaseAllowance(address(ROUTER_ADDRESS), MAX_INT);
        IERC20(path[1]).safeIncreaseAllowance(address(ROUTER_ADDRESS), MAX_INT);
        IERC20(path[2]).safeIncreaseAllowance(address(ROUTER_ADDRESS), MAX_INT);

        address pair = IUniswapV2Factory(FACTORY_ADDRESS).getPair(
            path[0],
            swapPairAddress
        );
        require(pair != address(0), "pool does not exist");

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        uint256 amount0Out = path[0] == token0 ? _amount : 0;
        uint256 amount1Out = path[0] == token1 ? _amount : 0;

        bytes memory data = abi.encode(path, _amount);

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);

        uint256 allowance0 = IERC20(path[0]).allowance(
            address(this),
            address(ROUTER_ADDRESS)
        );
        uint256 allowance1 = IERC20(path[1]).allowance(
            address(this),
            address(ROUTER_ADDRESS)
        );
        uint256 allowance2 = IERC20(path[2]).allowance(
            address(this),
            address(ROUTER_ADDRESS)
        );

        IERC20(path[0]).safeDecreaseAllowance(
            address(ROUTER_ADDRESS),
            allowance0
        );
        IERC20(path[1]).safeDecreaseAllowance(
            address(ROUTER_ADDRESS),
            allowance1
        );
        IERC20(path[2]).safeDecreaseAllowance(
            address(ROUTER_ADDRESS),
            allowance2
        );
    }
}
