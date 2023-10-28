// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/ISwapRouter.sol";
import "v3-periphery/interfaces/IQuoter.sol";

contract UniswapV3BotContract is Ownable, Pausable {
    using SafeERC20 for IERC20;

    address private constant FACTORY_ADDRESS =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address private constant ROUTER_ADDRESS =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant QUOTER_ADDRESS =
        0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

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

    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    function placeTrade(
        address _fromToken,
        address _toToken,
        uint24 _fee,
        uint256 _amountIn
    ) private returns (uint256) {
        address pool = IUniswapV3Factory(FACTORY_ADDRESS).getPool(
            _fromToken,
            _toToken,
            _fee
        );
        require(pool != address(0), "pool does not exist");

        uint256 amountRequired = IQuoter(QUOTER_ADDRESS).quoteExactInputSingle(
            _fromToken,
            _toToken,
            _fee,
            _amountIn,
            0
        );

        uint256 amountReceived = ISwapRouter(ROUTER_ADDRESS).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _fromToken,
                tokenOut: _toToken,
                fee: _fee,
                recipient: address(this),
                deadline: deadline,
                amountIn: _amountIn,
                amountOutMinimum: amountRequired,
                sqrtPriceLimitX96: 0
            })
        );

        require(amountReceived > 0, "Aborted tx: Trade returned zero");
        return amountReceived;
    }

    function uniswapV3FlashCallback(
        uint256 _fee0,
        uint256 _fee1,
        bytes calldata _data
    ) external {
        address token0 = IUniswapV3Pool(msg.sender).token0();
        address token1 = IUniswapV3Pool(msg.sender).token1();

        (
            address _sender,
            uint24 flashFee,
            address[] memory path,
            uint24[] memory fees,
            uint256 amount
        ) = abi.decode(_data, (address, uint24, address[], uint24[], uint256));

        address pool = IUniswapV3Factory(FACTORY_ADDRESS).getPool(
            token0,
            token1,
            flashFee
        );
        require(msg.sender == pool, "the sender needs to match pool contract");
        require(
            _sender == address(this),
            "the sender should match this contract"
        );

        uint256 fee = _fee0 > 0 ? _fee0 : _fee1;
        uint256 amountToRepay = amount + fee;

        uint256 trade1AcquiredCoin = placeTrade(
            path[0],
            path[1],
            fees[0],
            amount
        );
        uint256 trade2AcquiredCoin = placeTrade(
            path[1],
            path[2],
            fees[1],
            trade1AcquiredCoin
        );
        uint256 trade3AcquiredCoin = placeTrade(
            path[2],
            path[3],
            fees[2],
            trade2AcquiredCoin
        );

        require(trade3AcquiredCoin > amountToRepay, "not profitable");

        IERC20(path[0]).transfer(pool, amountToRepay);
    }

    function startArbitrage(
        address flashPairAddress,
        uint24 flashFee,
        address[] calldata path,
        uint24[] calldata fees,
        uint256 _amount
    ) external whenNotPaused onlyOwner {
        IERC20(path[0]).approve(address(ROUTER_ADDRESS), MAX_INT);
        IERC20(path[1]).approve(address(ROUTER_ADDRESS), MAX_INT);
        IERC20(path[2]).approve(address(ROUTER_ADDRESS), MAX_INT);

        address pool = IUniswapV3Factory(FACTORY_ADDRESS).getPool(
            path[0],
            flashPairAddress,
            flashFee
        );

        require(pool != address(0), "pool does not exist");

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        uint256 amount0Out = path[0] == token0 ? _amount : 0;
        uint256 amount1Out = path[0] == token1 ? _amount : 0;

        bytes memory data = abi.encode(
            address(this),
            flashFee,
            path,
            fees,
            _amount
        );

        IUniswapV3Pool(pool).flash(address(this), amount0Out, amount1Out, data);
        IERC20(path[0]).approve(address(ROUTER_ADDRESS), 0);
        IERC20(path[1]).approve(address(ROUTER_ADDRESS), 0);
        IERC20(path[2]).approve(address(ROUTER_ADDRESS), 0);
    }
}
