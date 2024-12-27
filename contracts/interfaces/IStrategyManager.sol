// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategyManager {
    struct Strategy {
        bool exists;
        bool active;
        uint256 addedTime;
    }

    struct StrategyInfo {
        uint256 chainID;
        address strategyAddress;
    }

    function getActiveAddrByChainId(
        uint256 _chainId
    ) external view returns (address[] memory);

    function addStrategy(uint256 _chainID, address _strategyAddress) external;

    function activateStrategy(
        uint256 _chainID,
        address _strategyAddress
    ) external;

    function removeStrategy(
        uint256 _chainID,
        address _strategyAddress
    ) external;

    function getAllActiveStrategies()
        external
        view
        returns (StrategyInfo[] memory);

    function getAllInactiveStrategies()
        external
        view
        returns (StrategyInfo[] memory);

    function isStrategyActive(
        uint256 _chainID,
        address _strategyAddress
    ) external view returns (bool);

    function getAllChainIDs() external view returns (uint256[] memory);

    function countChainIDs() external view returns (uint256);
}
