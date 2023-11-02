// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/ISwapRouter.sol";
import "v3-periphery/interfaces/IQuoterV2.sol";

contract UniswapV3BotContract is Ownable, Pausable {
    using SafeERC20 for IERC20;

    address private constant FACTORY_ADDRESS =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address private constant ROUTER_ADDRESS =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant QUOTER_ADDRESS =
        0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    constructor() Ownable(msg.sender) {}

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    receive() external payable {}

    function fundContract(
        address _token,
        uint256 _amount
    ) public payable onlyOwner {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    function withdrawToken(address _token, uint256 _amount) public onlyOwner {
        IERC20(_token).safeTransferFrom(address(this), msg.sender, _amount);
    }

    function withdrawETH(uint256 _amount) public onlyOwner {
        bool sent = payable(msg.sender).send(_amount);
        require(sent, "Failed to send Ether");
    }

    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
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
            address[] memory path,
            uint24[] memory fees,
            uint24 flashFee,
            uint256 amount
        ) = abi.decode(_data, (address, address[], uint24[], uint24, uint256));

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

        bytes memory input = abi.encodePacked(
            path[0],
            fees[0],
            path[1],
            fees[1],
            path[2],
            fees[2],
            path[3]
        );

        uint256 fee = _fee0 > 0 ? _fee0 : _fee1;
        uint256 amountToRepay = amount + fee;

        (
            uint256 amountRequired,
            uint160[] memory _price,
            uint32[] memory _ticks,
            uint256 _gas
        ) = IQuoterV2(QUOTER_ADDRESS).quoteExactInput(input, amount);

        uint256 amountReceived = ISwapRouter(ROUTER_ADDRESS).exactInput(
            ISwapRouter.ExactInputParams({
                path: input,
                recipient: address(this),
                deadline: block.timestamp + 1 days,
                amountIn: amount,
                amountOutMinimum: amountRequired
            })
        );

        require(amountReceived > amountToRepay, "not profitable");

        IERC20(path[0]).safeTransfer(pool, amountToRepay);
    }

    function startArbitrage(
        address flashPairAddress,
        uint24 flashFee,
        address[] calldata path,
        uint24[] calldata fees,
        uint256 _amount
    ) external whenNotPaused onlyOwner {
        IERC20(path[0]).forceApprove(
            address(ROUTER_ADDRESS),
            type(uint256).max
        );
        IERC20(path[1]).forceApprove(
            address(ROUTER_ADDRESS),
            type(uint256).max
        );
        IERC20(path[2]).forceApprove(
            address(ROUTER_ADDRESS),
            type(uint256).max
        );

        address pool = IUniswapV3Factory(FACTORY_ADDRESS).getPool(
            path[0],
            flashPairAddress,
            flashFee
        );

        require(pool != address(0), "pool does not exist");

        uint256 amount0Out = path[0] == IUniswapV3Pool(pool).token0()
            ? _amount
            : 0;
        uint256 amount1Out = path[0] == IUniswapV3Pool(pool).token1()
            ? _amount
            : 0;

        bytes memory data = abi.encode(
            address(this),
            path,
            fees,
            flashFee,
            _amount
        );

        IUniswapV3Pool(pool).flash(address(this), amount0Out, amount1Out, data);
        IERC20(path[0]).forceApprove(address(ROUTER_ADDRESS), 0);
        IERC20(path[1]).forceApprove(address(ROUTER_ADDRESS), 0);
        IERC20(path[2]).forceApprove(address(ROUTER_ADDRESS), 0);
    }
}
