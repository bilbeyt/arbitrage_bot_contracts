// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface IGasOracle{
    function getL1Fee(bytes memory _data) external view returns (uint256);
    function gasPrice() external view returns (uint256);
    function baseFee() external view returns (uint256);
    function overhead() external view returns (uint256);
    function scalar() external view returns (uint256);
    function l1BaseFee() external view returns (uint256);
    function decimals() external pure returns (uint256);
    function getL1GasUsed(bytes memory _data) external view returns (uint256);
}