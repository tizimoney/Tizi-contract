// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWTD {
    function viewRatio() external view returns (uint256);

    function updateRatio() external;

    function tdToWtd(uint256 _amount) external view returns (uint256);

    function wtdToTd(uint256 _amount) external view returns (uint256);

    function deposit(uint256 _wad) external;

    function withdraw(uint256 _wad) external;
}
