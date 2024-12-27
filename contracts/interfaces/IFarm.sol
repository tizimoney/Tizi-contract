// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ISharedStructs} from "./ISharedStructs.sol";

interface IFarm is ISharedStructs {
    struct TokenInfo {
        address tokenAddress;
        uint256 timestamp;
        bool negativeGrowth;
        uint256 tokenAmount;
        uint256 tokenValue;
    }

    struct CheckInfo {
        uint256 amount;
        bool negativeGrowth;
        uint256 timestamp;
    }

    struct EarlierProfits {
        CheckInfo[] checkList;
    }

    event Deposit(address indexed sender, uint256 amount);

    event Withdraw(address indexed sender, uint256 amount);

    event Harvest(address indexed sender);

    event ToVault(address indexed sender, uint256 amount, address indexed to);

    event Seize(address indexed to, uint256 amount);

    event TokenSwap(uint256 amount);

    event EmergencyStop(
        address indexed sender,
        address indexed to,
        uint256 amount
    );

    function check() external view returns (EarlierProfits[] memory);

    function deposit(uint256 _amountm, bool checkPoint) external;

    function withdraw(uint256 _amount) external returns (uint256);

    function harvest() external;

    function toVault(uint256 _amount) external;

    function seize(address token) external;

    function swap(
        address token,
        address router,
        SwapExecutionParams memory request
    ) external;

    function emergencyStop() external;

    function getTokenInfo() external view returns (TokenInfo[] memory);

    function withdrawableAmount() external view returns (uint256);

    function getTokenAddress() external view returns (address[] memory);
}
