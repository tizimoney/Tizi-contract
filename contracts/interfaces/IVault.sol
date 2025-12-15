// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ISharedStructs} from "./ISharedStructs.sol";

interface IVault is ISharedStructs {
    function enterFarm(uint256 chainId, address farm, uint256 amount) external returns (bool);

    function sendToUser(address to, uint256 amount) external returns (bool);

    function check(uint256 chainId, address farm) external view returns (uint256[] memory);

    function deposit(uint256 chainId, address farm, uint256 amount) external;

    function withdraw(uint256 chainId, address farm, uint256 amount) external;

    function harvest(uint256 chainId, address farm) external;

    function exitFarm(uint256 chainId, address farm, uint256 amount) external;

    function withdrawableAmount(uint256 chainId, address farm) external view returns (uint256);
}
