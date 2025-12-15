// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHelper {
    struct WithdrawDetails {
        uint256 amount;
        bool status;
    }

    struct Strategy {
        uint256 chainID;
        address strategyAddress;
        bool status;
    }

    struct WithdrawNFT {
        uint256 tokenId;
        uint256 mintTime;
        uint256 amount;
        uint256 queueId;
        uint256 expireDate;
    }

    function balanceOfUSDC(address a) external view returns (uint256);

    function balanceOfTiziDollar(address a) external view returns (uint256);

    function tdExchangeAmount(uint256 amount) external view returns (uint256);

    function tdExchangeRate() external pure returns (uint256);

    function deposit(uint256 amountWei) external;

    function queueWithdraw(uint256 amount) external returns (bytes32);

    function withdrawFromNFT(uint256 nftId) external;

    function withdrawAllNFT() external;

    function NFTWaitQueue(address user) external view returns (uint256[] memory);

    function NFTWithdrawQueue(address user) external view returns (uint256[] memory);

    function withdrawNFTs(
        uint256 id
    ) external view returns (WithdrawNFT memory);

    function nftQueueUSDC() external view returns (uint256);

    function calculateLiquidity() external view returns (uint256 liquidity, bool canActive);
}
