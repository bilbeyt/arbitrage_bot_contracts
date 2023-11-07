// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";

contract UniswapBotContract is Ownable, IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    address private constant ROUTER_ADDRESS =
        0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address private constant VAULT_ADDRESS =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address private constant QUOTER_ADDRESS =
        0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address private constant V2_QUOTER_ADDRESS =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    constructor() Ownable() {}

    function getV3Quote(
        address[] calldata tokens,
        uint24[] calldata fees,
        uint256 amountIn
    ) public returns (uint256) {
        bytes memory path = getV3Path(tokens, fees);
        (uint256 out, , , ) = IQuoterV2(QUOTER_ADDRESS).quoteExactInput(
            path,
            amountIn
        );
        return out;
    }

    function getV2Quote(
        address[] calldata tokens,
        uint256 amountIn
    ) public view returns (uint256) {
        uint256[] memory amounts = IUniswapV2Router02(V2_QUOTER_ADDRESS)
            .getAmountsOut(amountIn, tokens);
        return amounts[amounts.length - 1];
    }

    function getV3Path(
        address[] calldata tokens,
        uint24[] calldata fees
    ) public pure returns (bytes memory path) {
        path = abi.encodePacked(tokens[0]);
        for (uint i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, fees[i], tokens[i + 1]);
        }
    }

    function getArbitrageInputForV3(
        address recipient,
        address[] calldata tokens,
        uint24[] calldata fees,
        uint256 amountIn,
        uint256 amountOut
    ) public pure returns (bytes memory) {
        bytes memory path = getV3Path(tokens, fees);
        return abi.encode(recipient, amountIn, amountOut, path, false);
    }

    function getArbitrageInputForV2(
        address recipient,
        address[] calldata tokens,
        uint256 amountIn,
        uint256 amountOut
    ) public pure returns (bytes memory) {
        return abi.encode(recipient, amountIn, amountOut, tokens, false);
    }

    function startArbitrage(
        address[] calldata tokens,
        uint256 borrowAmount,
        bytes memory commands,
        bytes[] calldata inputs
    ) external onlyOwner {
        bytes memory data = abi.encode(address(this), commands, inputs);
        IERC20[] memory assets = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = IERC20(tokens[0]);
        amounts[0] = borrowAmount;
        IVault(VAULT_ADDRESS).flashLoan(this, assets, amounts, data);
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == VAULT_ADDRESS, "caller should be vault");
        (address _sender, bytes memory _commands, bytes[] memory _inputs) = abi
            .decode(userData, (address, bytes, bytes[]));
        require(_sender == address(this), "address should be bot contract");
        uint256 payment = amounts[0] + feeAmounts[0];
        uint256 oldBal = IERC20(tokens[0]).balanceOf(address(this)) -
            amounts[0];
        IERC20(tokens[0]).safeTransfer(ROUTER_ADDRESS, amounts[0]);
        IUniversalRouter(ROUTER_ADDRESS).execute(
            _commands,
            _inputs,
            block.timestamp + 1 days
        );
        uint256 newBal = IERC20(tokens[0]).balanceOf(address(this));

        require(newBal > payment, "not profitable");
        IERC20(tokens[0]).safeTransfer(VAULT_ADDRESS, payment);
        uint256 finalBal = IERC20(tokens[0]).balanceOf(address(this));
        require(finalBal > oldBal, "not profitable");
        IERC20(tokens[0]).safeTransfer(owner(), finalBal);
    }
}
