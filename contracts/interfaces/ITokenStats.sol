// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenStats {
    struct TokenInfo {
        address tokenAddress;
        uint256 timestamp;
        bool negativeGrowth;
        uint256 tokenAmount;
        uint256 tokenValue;
    }

    struct Strategy {
        uint256 chainID;
        address contractAddress;
        TokenInfo[] tokenInfo;
    }

    function getChainID() external view returns (uint256[] memory);

    function strategiesStats() external;

    function updateFromStructs(Strategy[] calldata infos) external;

    function getStrategyTokenInfo(
        uint256 chainID,
        address contractAddress
    ) external view returns (TokenInfo[] memory);

    function getStrategiesForChain(
        uint256 chainID
    ) external view returns (Strategy[] memory);

    function getAllStrategies() external view returns (Strategy[] memory);

    function getTokenInfoByAddresses(
        uint256 chainID,
        address strategyAddress,
        address tokenAddress
    ) external view returns (TokenInfo memory);

    function calculateTotalChainValues()
        external
        view
        returns (uint256 totalValue);

    function getChainTotalValues(
        uint256 chainID
    ) external view returns (uint256);

    function getStrategyTotalValues(
        uint256 chainID,
        address strategyAddress
    ) external view returns (uint256);

    function clearDataByChainId(uint256 _chainID) external;

    function calculateAndStoreValues() external;
}
