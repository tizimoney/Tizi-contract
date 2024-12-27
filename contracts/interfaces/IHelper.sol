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

    function balanceofUSDC(address a) external view returns (uint256);

    function balanceofTiziDollar(address a) external view returns (uint256);

    function TDExchangeAmount(uint256 amount) external view returns (uint256);

    function DDExchangeRate() external pure returns (uint256);

    function deposit(uint256 amount_wei) external;

    function updateExpireDate() external returns (bool);

    function queueWithdraw(uint256 amount) external returns (bytes32);

    function withdrawFromNFT(uint256 _queueId) external;

    function withdrawAllNFT() external;

    function NFTWaitQueue() external view returns (uint256[] memory);

    function NFTWithdrawQueue() external view returns (uint256[] memory);

    function withdrawNFTs(
        uint256 id
    ) external view returns (WithdrawNFT memory);

    function nftQueueUSDC() external view returns (uint256);
}
