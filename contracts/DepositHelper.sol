// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { INFT } from "./interfaces/INFT.sol";
import { IVault } from "./interfaces/IVault.sol";
import { ITD } from "./interfaces/ITD.sol";

/**
 * @title Tizi DepositHelper
 * @author tizi.money
 * @notice
 *  The DepositHelper contract is used for user deposits and withdrawals.
 *  Deployed only on the Base chain.
 *  When depositing, TD is minted at a ratio of 1:1 (excluding tax rate).
 *  There are two results when withdrawing. When there is sufficient funds
 *  in MainVault, USDC will be directly withdrawn and then TD will be burned.
 *  When the balance in MainVault is insufficient, an NFT will be minted to
 *  the user, and the NFT will record the available amount. Then the administrator
 *  will transfer part of the funds to NFTVault and make part of the NFT
 *  available. At this time, the user can withdraw USDC in the NFT.
 */
contract DepositHelper is ReentrancyGuard {
    uint256 public constant PRECISION_DELTA = 10 ** 12;
    uint256 public feeBasisPoints = 40;
    address public tiziDollar;
    address public USDC;
    address public vault;
    address public nft;
    uint256 public nftQueueUSDC;
    address public nftVault;

    uint256 private _nftQueueIds;
    IAuthorityControl private _authorityControl;

    struct WithdrawNFT {
        uint256 tokenId;
        uint256 mintTime;
        uint256 amount;
        uint256 queueId;
        bool canWithdraw;
    }

    mapping(uint256 => WithdrawNFT) public withdrawNFTs;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _tiziDollar,
        address _usdc,
        address _vault,
        address _nft,
        address _nftVault
    ) {
        _authorityControl = IAuthorityControl(_accessAddr);
        tiziDollar = _tiziDollar;
        USDC = _usdc;
        vault = _vault;
        nft = _nft;
        nftVault = _nftVault;
    }

    /*    -------------- Events --------------    */
    event Deposit(address indexed sender, uint256 amount);
    event Withdraw(address indexed sender, uint256 amount);
    event MintTiziDollar(
        address indexed wallet,
        uint256 amount,
        address tokenAddress
    );
    event QueueID(bytes32 txId);
    event SetFeeBasisPoints(address indexed sender, uint256 feeBasisPoints);
    event TransferToNFTVault(uint256 amount, uint256 count, uint256 time);
    event SetNewTD(address newTD);
    event SetNewVault(address newVault);
    event SetNewNFT(address newNFT);
    event SetNewNFTVault(address newNFTVault);

    /*    ------------- Modifiers ------------    */
    modifier onlyAdmin() {
        require(
            _authorityControl.hasRole(
                _authorityControl.DEFAULT_ADMIN_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        _;
    }

    /*    ---------- Read Functions -----------    */
    function balanceOfUSDC(address account) public view returns (uint256) {
        return IERC20(USDC).balanceOf(account);
    }

    function balanceOfTiziDollar(address account) public view returns (uint256) {
        return ITD(tiziDollar).balanceOf(account);
    }

    function tdExchangeAmount(uint256 amount) public view returns (uint256) {
        uint256 tdAmount = amount * tdExchangeRate() / 100000;
        return tdAmount;
    }

    function tdExchangeRate() public view returns (uint256) {
        return 100000 - feeBasisPoints;
    }

    function getTxId(
        uint256 timestamp,
        uint256 amount,
        address walletAddress
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(timestamp, amount, walletAddress));
    }

    /// @notice Calculate the balance in the vault minus the balance waiting in the NFT.
    /// @return liquidity and Can the strategy be activated
    function calculateLiquidity() public view returns (uint256 liquidity, bool canActive) {
        uint256 totalFunds = IERC20(USDC).balanceOf(vault);
        uint256 waitAmount = getWaitNFTAmount();
        if(waitAmount == 0) {
            return (totalFunds, true);
        } else {
            if (totalFunds <= waitAmount) {
                return (0, false);
            } else {
                liquidity = totalFunds - waitAmount;
                return (liquidity, true);
            }
        }
    }

    /// @notice Calculate the amount of USDC in NFTs that can be taken.
    function getWithdrawNFTAmount() public view returns (uint256) {
        uint256 count;
        uint256 withdrawAmount = countAllWithdrawNFT();
        uint256[] memory withdrawIds = getAllWithdrawNFTIds();
        for (uint256 i = 0; i < withdrawAmount; i++) {
            uint256 nftId = withdrawIds[i];
            if(withdrawNFTs[nftId].mintTime != 0) {
                count += withdrawNFTs[nftId].amount;
            }
        }
        return count;
    }

    /// @notice Calculate the amount of USDC in NFTs waiting.
    function getWaitNFTAmount() public view returns (uint256) {
        uint256 count;
        uint256 waitAmount = countAllWaitNFT();
        uint256[] memory waitIds = getAllWaitNFTIds();
        for (uint256 i = 0; i < waitAmount; i++) {
            uint256 nftId = waitIds[i];
            if(withdrawNFTs[nftId].mintTime != 0) {
                count += withdrawNFTs[nftId].amount;
            }
        }
        return count;
    }

    /// @notice Calculate the amount of USDC in NFT of msg.sender.
    function calculateUserTotalNFTFunds(address user) public view returns (uint256) {
        uint256 amount;
        uint256[] memory nftWithdrawQueue = NFTWithdrawQueue(user);
        if (nftWithdrawQueue.length > 0) {
            for (uint i = 0; i < nftWithdrawQueue.length; i++) {
                uint256 queueId = nftWithdrawQueue[i];
                if(withdrawNFTs[queueId].mintTime != 0){
                    amount += withdrawNFTs[queueId].amount;
                }
            }
        }
        return amount;
    }

    /// @notice Get all waiting NFTs of msg.sender.
    /// @return TokenIDs of NFT.
    function NFTWaitQueue(address user) public view returns (uint256[] memory) {
        uint256[] memory queue = INFT(nft).ownerTokenIds(user);
        uint256 waitLength = countUsersWaitNFT(user);
        uint256 count = 0;
        uint256[] memory nftQueue = new uint256[](waitLength);
        if (queue.length > 0) {
            for (uint i = 0; i < queue.length; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].mintTime != 0 && withdrawNFTs[queueId].canWithdraw == false) {
                    nftQueue[count] = withdrawNFTs[queueId].tokenId;
                    count++;
                }
            }
        }
        return nftQueue;
    }

    /// @notice Get all withdrawing NFTs of msg.sender.
    /// @return withdrawQueue TokenIDs of NFT.
    function NFTWithdrawQueue(address user) public view returns (uint256[] memory) {
        uint256[] memory queue = INFT(nft).ownerTokenIds(user);
        uint256 withdrawLength = queue.length - countUsersWaitNFT(user);
        uint256 count = 0;
        uint256[] memory nftQueue = new uint256[](withdrawLength);
        if (queue.length > 0) {
            for (uint i = 0; i < queue.length; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].mintTime != 0 && withdrawNFTs[queueId].canWithdraw == true) {
                    nftQueue[count] = withdrawNFTs[queueId].tokenId;
                    count++;
                }
            }
        }
        return nftQueue;
    }

    /// @notice Get the amount of waiting NFTs of msg.sender.
    /// @return Amount of NFT.
    function countUsersWaitNFT(address user) public view returns (uint256) {
        uint256 count;
        uint256[] memory queue = INFT(nft).ownerTokenIds(user);
        uint256 nftLength = queue.length;
        if (nftLength > 0) {
            for (uint i = 0; i < nftLength; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].mintTime != 0 && withdrawNFTs[queueId].canWithdraw == false) {
                    count++;
                }
            }
        }
        return count;
    }

    /// @notice Get the amount of withdrawing NFTs of msg.sender.
    /// @return Amount of NFT.
    function usersWaitNFTAmount(address user) public view returns (uint256) {
        uint256 count;
        uint256[] memory queue = INFT(nft).ownerTokenIds(user);
        uint256 nftLength = queue.length;
        if (nftLength > 0) {
            for (uint i = 0; i < nftLength; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].mintTime != 0 && withdrawNFTs[queueId].canWithdraw == false) {
                    count = count + withdrawNFTs[queueId].amount;
                }
            }
        }
        return count;
    }

    /// @notice Get all waiting NFTs.
    /// @return TokenIDs of NFT.
    function getAllWaitNFTIds() public view returns (uint256[] memory) {
        uint256 waitAmount = countAllWaitNFT();
        uint256[] memory nftIds = new uint256[](waitAmount);
        uint256 totalSupply = INFT(nft).totalSupply();
        uint256 idx = 0;
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].mintTime != 0 && withdrawNFTs[nftId].canWithdraw == false) {
                nftIds[idx] = nftId;
                idx++;
            }
        }
        return nftIds;
    }

    /// @notice Get all withdrawing NFTs.
    /// @return TokenIDs of NFT.
    function getAllWithdrawNFTIds() public view returns (uint256[] memory) {
        uint256 withdrawAmount = countAllWithdrawNFT();
        uint256[] memory nftIds = new uint256[](withdrawAmount);
        uint256 totalSupply = INFT(nft).totalSupply();
        uint256 idx = 0;
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].mintTime != 0 && withdrawNFTs[nftId].canWithdraw == true) {
                nftIds[idx] = nftId;
                idx++;
            }
        }
        return nftIds;
    }

    /// @notice Get the amount of USDC in all NFTs.
    /// @return Amount of USDC.
    function getAllNFTAmount() public view returns (uint256) {
        uint256 count;
        uint256 totalSupply = INFT(nft).totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            count += withdrawNFTs[nftId].amount;
        }
        return count;
    }

    /// @notice Get the amount of waiting NFTs.
    /// @return Amount of NFT.
    function countAllWaitNFT() public view returns (uint256) {
        uint256 count;
        uint256 totalSupply = INFT(nft).totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].mintTime != 0 && withdrawNFTs[nftId].canWithdraw == false) {
                count++;
            }
        }
        return count;
    }

    /// @notice Get the amount of withdrawing NFTs.
    /// @return Amount of NFT.
    function countAllWithdrawNFT() public view returns (uint256) {
        uint256 count;
        uint256 totalSupply = INFT(nft).totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].mintTime != 0 && withdrawNFTs[nftId].canWithdraw == true) {
                count++;
            }
        }
        return count;
    }

    /*    ---------- Write Functions ----------    */
    function _transferFromWallet(uint256 amountWei) private returns (bool) {
        bool success = IERC20(USDC).transferFrom(msg.sender, vault, amountWei);
        return success;
    }

    function _mint(address user, uint256 amount) private {
        ITD(tiziDollar).mint(amount, user);
        emit MintTiziDollar(user, amount, tiziDollar);
    }

    /// @notice Called by user, deposit to project.
    /// @param amountWei The amount of USDC in wei.
    function deposit(uint256 amountWei) external nonReentrant {
        require(amountWei >= 10 ** 6, "Minimum deposit: 1 USDC.");
        uint256 usdcAmount = amountWei * PRECISION_DELTA;
        require(
            balanceOfUSDC(msg.sender) >= amountWei,
            "Insufficient token balance"
        );
        require(
            _transferFromWallet(amountWei) == true,
            "USDC transfer unsuccessful"
        );
        uint256 tdAmount = usdcAmount;
        _mint(msg.sender, tdAmount);
        emit Deposit(msg.sender, amountWei);
    }

    /// @notice When the mainVault balance is insufficient, an NFT will be minted for the user.
    /// @param amount The amount of USDC in NFT.
    /// @return Txid.
    function _queueNFT(uint256 amount) private returns (bytes32) {
        uint256 tokenId = INFT(nft).mint(msg.sender);
        WithdrawNFT memory withdrawNFT = WithdrawNFT(
            tokenId,
            block.timestamp,
            amount,
            _nftQueueIds,
            false
        );
        withdrawNFTs[_nftQueueIds] = withdrawNFT;
        bytes32 txId = keccak256(
            abi.encode(
                tokenId,
                block.timestamp,
                amount,
                _nftQueueIds,
                false
            )
        );
        nftQueueUSDC = nftQueueUSDC + amount;
        _nftQueueIds++;
        emit QueueID(txId);
        return txId;
    }

    /// @notice Called by manager, make some NFTs withdrawable based on the balance in mainVault.
    function fulfillNFT() external onlyAdmin returns (bool) {
        uint256[] memory nftIds = getAllWaitNFTIds();
        uint256 disposable = IERC20(USDC).balanceOf(vault);
        uint256 amountOut = 0;
        uint256 count = 0;
        for (uint i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            if (withdrawNFTs[nftId].amount <= disposable) {
                withdrawNFTs[nftId].canWithdraw = true;
                disposable -= withdrawNFTs[nftId].amount;
                amountOut += withdrawNFTs[nftId].amount;
                count++;
            }
        }

        require(
            amountOut <= IERC20(USDC).balanceOf(vault),
            "Amount out token bigger than vault balance"
        );

        require(
            IVault(vault).sendToUser(nftVault, amountOut) == true,
            "transfer failed"
        );
        emit TransferToNFTVault(amountOut, count, block.timestamp);
        return true;
    }

    function fulfillNFTBatch(uint256[] calldata nftIds) external onlyAdmin returns (bool) {
        uint256 disposable = IERC20(USDC).balanceOf(vault);
        uint256 amountOut = 0;
        uint256 count = 0;
        for (uint i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            if (withdrawNFTs[nftId].mintTime != 0 && withdrawNFTs[nftId].canWithdraw == false) {
                uint256 amt = withdrawNFTs[nftId].amount;
                if (amt <= disposable) {
                    withdrawNFTs[nftId].canWithdraw = true;
                    disposable -= amt;
                    amountOut += amt;
                    count++;
                }
            }
        }
        require(amountOut <= IERC20(USDC).balanceOf(vault), "Amount out token bigger than vault balance");
        require(IVault(vault).sendToUser(nftVault, amountOut), "Transfer failed");
        emit TransferToNFTVault(amountOut, count, block.timestamp);
        return true;
    }

    /// @notice Called by user, when the balance in mainVault is greater than amount,
    /// send USDC directly, otherwise mint an NFT.
    /// @param amount The amount of USDC to withdraw.
    /// @return Txid.
    function queueWithdraw(
        uint256 amount
    ) external nonReentrant returns (bytes32) {
        bytes32 txId;
        require(
            balanceOfTiziDollar(msg.sender) >= amount,
            "Insufficient TD Token"
        );
        uint256 netAmount = tdExchangeAmount(amount);
        ITD(tiziDollar).burn(amount, msg.sender);
        uint256 liquidity = IERC20(USDC).balanceOf(vault);
        uint256 remainder = netAmount % PRECISION_DELTA;
        uint256 usdcAmount = 0;
        if (2 * remainder >= PRECISION_DELTA) {
            usdcAmount = (netAmount / PRECISION_DELTA) + 1;
        } else {
            usdcAmount = netAmount / PRECISION_DELTA;
        }
        if (usdcAmount <= liquidity) {
            txId = _withdrawCallback(usdcAmount);
            emit Withdraw(msg.sender, amount);
            return txId;
        } else {
            txId = _queueNFT(usdcAmount);
            return txId;
        }
    }

    function _withdrawCallback(uint256 amount) private returns (bytes32) {
        bytes32 txId;
        bool result = IVault(vault).sendToUser(msg.sender, amount);
        require(result == true, "transfer failed");
        txId = keccak256(abi.encode(msg.sender, amount, result));
        return txId;
    }

    /// @notice Used to withdraw an NFT.
    /// @param nftId The id of NFT.
    function withdrawFromNFT(uint256 nftId) external nonReentrant {
        require(
            withdrawNFTs[nftId].mintTime != 0,
            "nft is not in the queue"
        );
        require(
            withdrawNFTs[nftId].canWithdraw == true,
            "nft has not able to withdraw"
        );
        WithdrawNFT memory withdrawNFT = withdrawNFTs[nftId];
        uint256 needFunds = withdrawNFT.amount;
        uint256 disposable = IERC20(USDC).balanceOf(nftVault);
        require(needFunds <= disposable, "Insufficient USDC");
        require(
            INFT(nft).ownerOf(withdrawNFT.tokenId) == msg.sender,
            "Invalid user"
        );
        require(INFT(nft).burn(withdrawNFT.tokenId) == true, "burn failed");
        require(
            IVault(nftVault).sendToUser(msg.sender, withdrawNFT.amount) == true,
            "transfer failed"
        );
        nftQueueUSDC = nftQueueUSDC - withdrawNFT.amount;
        delete withdrawNFTs[nftId];
    }

    /// @notice Used to withdraw all withdrawable NFTs of msg.sender.
    function withdrawAllNFT() external nonReentrant {
        uint256[] memory nftWithdrawQueue = NFTWithdrawQueue(msg.sender);
        require(nftWithdrawQueue.length > 0, "No NFT can be extracted");
        uint256 disposable = IERC20(USDC).balanceOf(nftVault);
        for (uint i = 0; i < nftWithdrawQueue.length; i++) {
            uint256 queueId = nftWithdrawQueue[i];
            require(withdrawNFTs[queueId].canWithdraw == true, "NFT can't withdraw");
            require(withdrawNFTs[queueId].amount <= disposable, "Insufficient USDC");
            require(
                INFT(nft).burn(withdrawNFTs[queueId].tokenId) == true,
                "burn failed"
            );
            require(
                IVault(nftVault).sendToUser(
                    msg.sender,
                    withdrawNFTs[queueId].amount
                ) == true,
                "transfer failed"
            );
            disposable -= withdrawNFTs[queueId].amount;
            nftQueueUSDC = nftQueueUSDC - withdrawNFTs[queueId].amount;
            delete withdrawNFTs[queueId];
        }
    }

    function setPoints(uint256 newPoints) external onlyAdmin {
        require(newPoints <= 40, "Cannot exceed 40!");
        feeBasisPoints = newPoints;
        emit SetFeeBasisPoints(msg.sender, newPoints);
    }

    function setTD(address newTD) external onlyAdmin {
        require(newTD != tiziDollar && newTD != address(0), "wrong address");
        tiziDollar = newTD;
        emit SetNewTD(newTD);
    }

    function setVault(address newVault) external onlyAdmin {
        require(newVault != vault && newVault != address(0), "Wrong address");
        vault = newVault;
        emit SetNewVault(newVault);
    }

    function setNFT(address newNFT) external onlyAdmin {
        require(newNFT != nft && newNFT != address(0), "Wrong address");
        nft = newNFT;
        emit SetNewNFT(newNFT);
    }

    function setNFTVault(address newNFTVault) external onlyAdmin {
        require(newNFTVault != nftVault && newNFTVault != address(0), "Wrong address");
        nftVault = newNFTVault;
        emit SetNewNFTVault(nftVault);
    }
}
