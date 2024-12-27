// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ISharedStructs} from "./ISharedStructs.sol";

interface IVault is ISharedStructs {
    function enterFarm(uint256 _chainId, address _farm, uint256 _amount) external returns (bool);

    function sendToUser(address _to, uint256 _amount) external returns (bool);

    function check(uint256 _chainId, address _farm) external view returns (uint256[] memory);

    function deposit(uint256 _chainId, address _farm, uint256 _amount) external;

    function withdraw(uint256 _chainId, address _farm, uint256 _amount) external;

    function harvest(uint256 _chainId, address _farm) external;

    function exitFarm(uint256 _chainId, address _farm, uint256 _amount) external;

    function withdrawableAmount(uint256 _chainId, address _farm) external view returns (uint256);

    function setProfitRate(uint256 _rate) external;

    function profitNumerator() external view returns (uint256);

    function profitDenominator() external view returns (uint256);

    function profitRecipient() external view returns (address);

    function getCurrentProfitUSDC(
        address _farm
    ) external view returns (uint256, uint256);

    function getCurrentProfitOthers(
        address _farm
    ) external view returns (uint256[] memory);

    function getTotalNetUSDC(address _farm) external view returns (uint256);

    function getTotalProfitUSDC(address _farm) external view returns (uint256);

    function principal(address _strategy) external view returns (uint256);
}
