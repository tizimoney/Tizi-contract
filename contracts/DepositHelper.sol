// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAuthorityControl} from "./interfaces/IAuthorityControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {INFT} from "./interfaces/INFT.sol";
import {IVault} from "./interfaces/IVault.sol";
import {ITD} from "./interfaces/ITD.sol";
import {RebaseTokenMath} from "./lib/RebaseTokenMath.sol";

contract DepositHelper is ReentrancyGuard {
    uint256 public constant PRECISION_DELTA = 10 ** 12;
    uint256 public constant DELAY = 1 days;
    uint256 public maxTDCount = 100000 * (10 ** 18);
    uint256 public feeBasisPoints = 40;
    using RebaseTokenMath for uint256;

    uint256 private nftQueueIds;
    address private TiziDollar;
    address private USDC;

    IAuthorityControl private authorityControl;

    struct WithdrawNFT {
        uint256 tokenId;
        uint256 mintTime;
        uint256 amount;
        uint256 queueId;
        bool canWithdraw;
    }

    mapping(uint256 => WithdrawNFT) public withdrawNFTs;

    address public vault;
    address public nft;
    uint256 public nftQueueUSDC;
    address public nftVault;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _tiziDollar,
        address _usdc,
        address _vault,
        address _nft,
        address _nftVault
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        TiziDollar = _tiziDollar;
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
    event MaxTDCountUpdated(address indexed sender, uint256 newMaxTDCount);
    event UpdateFeeBasisPoints(address indexed sender, uint256 feeBasisPoints);
    event TransferToNFTVault(uint256 amount, uint256 count, uint256 time);

    /*    ------------- Modifiers ------------    */
    modifier onlyAdmin() {
        require(
            authorityControl.hasRole(
                authorityControl.DEFAULT_ADMIN_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        _;
    }

    /*    ---------- Read Functions -----------    */
    function balanceofUSDC(address a) public view returns (uint256) {
        return IERC20(USDC).balanceOf(a);
    }

    function balanceofTiziDollar(address a) public view returns (uint256) {
        return ITD(TiziDollar).balanceOf(a);
    }

    function TDExchangeAmount(uint256 amount) public view returns (uint256) {
        uint256 DDamount = amount - ((amount * feeBasisPoints) / 100000);
        return DDamount;
    }

    function DDExchangeRate() public view returns (uint256) {
        return 100000 - feeBasisPoints;
    }

    function getTxId(
        uint256 _timestamp,
        uint256 _amount,
        address _walletAddress
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(_timestamp, _amount, _walletAddress));
    }

    /// @notice Calculate the balance in the vault minus the balance waiting in the NFT.
    function _calculateLiquidity() private view returns (uint256) {
        uint256 totalFunds = IERC20(USDC).balanceOf(vault);
        if (totalFunds <= nftQueueUSDC) {
            return 0;
        }
        uint256 liquidity = totalFunds - nftQueueUSDC;
        return liquidity;
    }

    /// @notice Calculate the amount of USDC in NFTs that can be taken.
    function _getWithdrawNFTAmount() private view returns (uint256) {
        uint256 count;
        uint256 withdrawAmount = _countAllWithdrawNFT();
        uint256[] memory withdrawIds = _getAllWithdrawNFTIds();
        for (uint256 i = 0; i < withdrawAmount; i++) {
            uint256 nftId = withdrawIds[i];
            count += withdrawNFTs[nftId].amount;
        }
        return count;
    }

    /// @notice Calculate the amount of USDC in NFTs waiting.
    function _getWaitNFTAmount() private view returns (uint256) {
        uint256 count;
        uint256 waitAmount = _countAllWaitNFT();
        uint256[] memory waitIds = _getAllWaitNFTIds();
        for (uint256 i = 0; i < waitAmount; i++) {
            uint256 nftId = waitIds[i];
            count += withdrawNFTs[nftId].amount;
        }
        return count;
    }

    /// @notice Calculate the amount of USDC in NFT of msg.sender.
    function _calculateUserTotalNFTFunds() private view returns (uint256) {
        uint256 amount;
        uint256[] memory nftWithdrawQueue = NFTWithdrawQueue();
        if (nftWithdrawQueue.length > 0) {
            for (uint i = 0; i < nftWithdrawQueue.length; i++) {
                uint256 queueId = nftWithdrawQueue[i];
                amount += withdrawNFTs[queueId].amount;
            }
        }
        return amount;
    }
    
    /// @notice Get all waiting NFTs of msg.sender.
    /// @return TokenIDs of NFT.
    function NFTWaitQueue() public view returns (uint256[] memory) {
        uint256[] memory queue = INFT(nft).ownerTokenIds(msg.sender);
        uint256 waitLength = _countUsersWaitNFT();
        uint256 count = 0;
        uint256[] memory nftQueue = new uint256[](waitLength);
        if (queue.length > 0) {
            for (uint i = 0; i < queue.length; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].canWithdraw == false) {
                    nftQueue[count] = withdrawNFTs[queueId].tokenId;
                    count++;
                }
            }
        }
        return nftQueue;
    }

    /// @notice Get all withdrawing NFTs of msg.sender.
    /// @return TokenIDs of NFT.
    function NFTWithdrawQueue() public view returns (uint256[] memory) {
        uint256[] memory queue = INFT(nft).ownerTokenIds(msg.sender);
        uint256 withdrawLength = queue.length - _countUsersWaitNFT();
        uint256 count = 0;
        uint256[] memory nftQueue = new uint256[](withdrawLength);
        if (queue.length > 0) {
            for (uint i = 0; i < queue.length; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].canWithdraw == true) {
                    nftQueue[count] = withdrawNFTs[queueId].tokenId;
                    count++;
                }
            }
        }
        return nftQueue;
    }

    /// @notice Get the amount of waiting NFTs of msg.sender.
    /// @return Amount of NFT.
    function _countUsersWaitNFT() private view returns (uint256) {
        uint256 count;
        uint256[] memory queue = INFT(nft).ownerTokenIds(msg.sender);
        uint256 nftLength = queue.length;
        if (nftLength > 0) {
            for (uint i = 0; i < nftLength; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].canWithdraw == false) {
                    count++;
                }
            }
        }
        return count;
    }

    /// @notice Get the amount of withdrawing NFTs of msg.sender.
    /// @return Amount of NFT.
    function _usersWaitNFTAmount() private view returns (uint256) {
        uint256 count;
        uint256[] memory queue = INFT(nft).ownerTokenIds(msg.sender);
        uint256 nftLength = queue.length;
        if (nftLength > 0) {
            for (uint i = 0; i < nftLength; i++) {
                uint256 queueId = queue[i];
                if (withdrawNFTs[queueId].canWithdraw == false) {
                    count = count + withdrawNFTs[queueId].amount;
                }
            }
        }
        return count;
    }

    /// @notice Get all waiting NFTs.
    /// @return TokenIDs of NFT.
    function _getAllWaitNFTIds() private view returns (uint256[] memory) {
        uint256 waitAmount = _countAllWaitNFT();
        uint256[] memory nftIds = new uint256[](waitAmount);
        for (uint256 i = 0; i < waitAmount; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].canWithdraw == false) {
                nftIds[i] = nftId;
            }
        }
        return nftIds;
    }

    /// @notice Get all withdrawing NFTs.
    /// @return TokenIDs of NFT.
    function _getAllWithdrawNFTIds() private view returns (uint256[] memory) {
        uint256 withdrawAmount = _countAllWithdrawNFT();
        uint256[] memory nftIds = new uint256[](withdrawAmount);
        for (uint256 i = 0; i < withdrawAmount; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].canWithdraw == true) {
                nftIds[i] = nftId;
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
    function _countAllWaitNFT() private view returns (uint256) {
        uint256 count;
        uint256 totalSupply = INFT(nft).totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if ( withdrawNFTs[nftId].canWithdraw == false) {
                count++;
            }
        }
        return count;
    }

    /// @notice Get the amount of withdrawing NFTs.
    /// @return Amount of NFT.
    function _countAllWithdrawNFT() private view returns (uint256) {
        uint256 count;
        uint256 totalSupply = INFT(nft).totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            uint256 nftId = INFT(nft).tokenByIndex(i);
            if (withdrawNFTs[nftId].canWithdraw == true) {
                count++;
            }
        }
        return count;
    }

    /*    ---------- Write Functions ----------    */
    function _transferFromWallet(uint256 amount_wei) private returns (bool) {
        bool b = IERC20(USDC).transferFrom(msg.sender, vault, amount_wei);
        return b;
    }

    function _mint(address _user, uint256 _amount) private {
        ITD(TiziDollar).mint(_amount, _user);
        emit MintTiziDollar(_user, _amount, TiziDollar);
    }

    /// @notice Called by user, deposit to project.
    /// @param amount_wei The amount of USDC in wei.
    function deposit(uint256 amount_wei) external nonReentrant {
        require(
            ITD(TiziDollar).isRebaseDisabled(msg.sender) == false,
            "The user cannot opt-out of rebase."
        );
        require(amount_wei >= 10 ** 6, "Minimum deposit: 1 USDC.");
        if (
            ITD(TiziDollar).totalSupply() <
            maxTDCount.toTokens(ITD(TiziDollar).rebaseIndex())
        ) {
            uint256 amount_tt = amount_wei * PRECISION_DELTA;
            require(
                TDExchangeAmount(amount_tt).toTokens(
                    ITD(TiziDollar).rebaseIndex()
                ) +
                    ITD(TiziDollar).totalSupply() <=
                    maxTDCount,
                "Deposit amount exceeds the limit"
            );
            require(
                balanceofUSDC(msg.sender) >= amount_wei,
                "Insufficient token balance"
            );
            require(
                _transferFromWallet(amount_wei) == true,
                "USDC transfer unsuccessful"
            );
            uint256 _TDamount = TDExchangeAmount(amount_tt);
            _mint(msg.sender, _TDamount);
            emit Deposit(msg.sender, amount_wei);
        } else {
            revert("Deposit limit reached");
        }
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
            nftQueueIds,
            false
        );
        withdrawNFTs[nftQueueIds] = withdrawNFT;
        bytes32 txId = keccak256(
            abi.encode(
                tokenId,
                block.timestamp,
                amount,
                nftQueueIds,
                false
            )
        );
        nftQueueUSDC = nftQueueUSDC + amount;
        nftQueueIds++;
        emit QueueID(txId);
        return txId;
    }

    /// @notice Called by manager, make some NFTs withdrawable based on the balance in mainVault.
    function fulfillNFT() external returns (bool) {
        require(
            authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        uint256[] memory nftIds = _getAllWaitNFTIds();
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

        require(amountOut <= IERC20(USDC).balanceOf(vault), 
            "Amount out token bigger than vault balance");
        
        IVault(vault).sendToUser(nftVault, amountOut);
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
        require(
            ITD(TiziDollar).isRebaseDisabled(msg.sender) == false,
            "The user cannot opt-out of rebase."
        );
        require(
            balanceofTiziDollar(msg.sender) >= amount,
            "Insufficient TD Token"
        );
        uint256 netAmount = TDExchangeAmount(amount);
        ITD(TiziDollar).burn(amount, msg.sender);
        uint256 liquidity = IERC20(USDC).balanceOf(vault);
        uint256 remainder = netAmount % PRECISION_DELTA;
        uint256 usdcAmount = 0;
        if (2 * remainder >= PRECISION_DELTA) {
            usdcAmount = (netAmount / PRECISION_DELTA) + 1;
        } else {
            usdcAmount = netAmount / PRECISION_DELTA;
        }
        if (usdcAmount <= liquidity) {
            bytes32 txId = withdraw_callback(usdcAmount);
            emit Withdraw(msg.sender, amount);
            return txId;
        } else {
            bytes32 txId = _queueNFT(usdcAmount);
            return txId;
        }
    }

    function withdraw_callback(uint256 _amount) private returns (bytes32) {
        bool result = IVault(vault).sendToUser(msg.sender, _amount);
        require(result == true, "transfer failed");
        bytes32 txId = keccak256(abi.encode(msg.sender, _amount, result));
        return txId;
    }

    /// @notice Used to withdraw an NFT.
    /// @param _queueId The id of NFT.
    function withdrawFromNFT(uint256 _queueId) external nonReentrant {
        require(
            withdrawNFTs[_queueId].mintTime != 0,
            "nft is not in the queue"
        );
        require(
            withdrawNFTs[_queueId].canWithdraw == true,
            "nft has not able to withdraw"
        );
        WithdrawNFT memory withdrawNFT = withdrawNFTs[_queueId];
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
        delete withdrawNFTs[_queueId];
    }

    /// @notice Used to withdraw all withdrawable NFTs of msg.sender.
    function withdrawAllNFT() external nonReentrant {
        uint256[] memory nftWithdrawQueue = NFTWithdrawQueue();
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

    function setMaxTDCount(uint256 _count) external onlyAdmin {
        maxTDCount = _count;
        emit MaxTDCountUpdated(msg.sender, _count);
    }

    function updatePoints(uint256 _points) external onlyAdmin {
        require(_points <= 40);
        feeBasisPoints = _points;
        emit UpdateFeeBasisPoints(msg.sender, _points);
    }
}
