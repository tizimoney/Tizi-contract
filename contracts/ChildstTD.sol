// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { ITD } from "./interfaces/ITD.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./utils/SafeMath.sol";

interface IStakingVault {
    function sendToUser(
        address _to, 
        uint256 _amount
    ) external returns (bool);
}

/**
 * @title Tizi ChildstTD
 * @author tizi.money
 * @notice
 *  The ChildstTD contract is a staked TD contract deployed on other chains.
 *  It does not have a stake function and only performs cross-chain functions.
 */
contract ChildstTD is ReentrancyGuard, ERC20Permit, ERC4626, OFT {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using OptionsBuilder for bytes;
    using Math for uint256;

    // Max withdraw cd time.
    uint24 public constant MAX_UNSTAKING_PERIOD = 90 days;
    uint24 public unstakingPeriod = 604800;
    uint256 public releasePeriod = 604800;
    uint256 public mainChainId;
    bytes public gasOptions;

    uint256 public stakedTDAmount;
    uint256 public totalShares;
    
    uint256 public releaseAmount;
    uint256 public lastYieldTime;

    address public profitRecipient;
    uint256 public profitNumerator = 100;
    uint256 public profitDenominator = 1000;
    uint256 public totalProfit;

    IERC20 public td;
    address public stakingVault;

    IAuthorityControl private _authorityControl;

    struct UserUnstakingInfo {
        uint256 endTime;
        uint256 amount;
    }

    mapping(address => UserUnstakingInfo[7]) public userUnstakingQueue;

    /*    -------------- Events --------------    */
    event YieldReceived(uint256 indexed amount, bool negativeGrowth);
    event SetNewUnstakingPeriod(uint256 indexed unstakingPeriod);
    event SetNewReleasePeriod(uint256 indexed releasePeriod);
    event SetNewTD(address indexed newTD);
    event SetNewStakingVault(address indexed newVault);
    event TransferProfit(address indexed profitRecipient, uint256 indexed amount);
    event SetNewProfitRecipient(address indexed profitRecipient);
    event SetNewProfitNumerator(uint256 indexed profitNumerator);
    event Stake(uint256 indexed assets, uint256 indexed shares, address indexed sender);
    event UnStake(uint256 indexed _shares, uint256 indexed _assets, address indexed sender);
    event Claim(uint256 indexed amountToClaim, address indexed sender);
    error UnsupportedChain(uint256 chainID);

    /*    ------------- Modifiers ------------    */
    modifier onlyManager() {
        require(
            _authorityControl.hasRole(
                _authorityControl.MANAGER_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        _;
    }

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

    /*    ------------ Constructor ------------    */
    constructor(
        IERC20 _td, 
        address _stakingVault,
        address _accessAddr,
        address _profitRecipient,
        address _lzEndpoint,
        address _delegate,
        uint256 _mainChainId
    )
        ERC4626(_td)
        ERC20Permit("stTD")
        OFT("Staked TD", "stTD", _lzEndpoint, _delegate)
        Ownable(_delegate)
    {
        td = _td;
        stakingVault = _stakingVault;
        _authorityControl = IAuthorityControl(_accessAddr);
        profitRecipient = _profitRecipient;
        mainChainId = _mainChainId;
    }

    /*    ---------- Read Functions -----------    */
    function totalAssets() public view override returns (uint256) {
        uint256 unreleasedAmount = getUnreleasedAmount();
        return stakedTDAmount >= unreleasedAmount ? stakedTDAmount.sub(unreleasedAmount) : 0;
    }

    /**
     * @dev ERC4626 and ERC20 define function with same name and parameter types.
     */
    function decimals() public pure override(ERC4626, ERC20) returns (uint8) {
        return 18;
    }

    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function bytes32ToAddress(bytes32 bytes32Address) public pure returns (address) {
        return address(uint160(uint256(bytes32Address)));
    }

    function getUserAllUnstakeInfo(address user) external view returns (UserUnstakingInfo[7] memory) {
        return userUnstakingQueue[user];
    }

    function asset() public view override returns (address) {
        return address(td);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return
            (assets == 0 || totalShares == 0)
                ? assets.mulDiv(10 ** decimals(), 10 ** 18, rounding)
                : assets.mulDiv(totalShares, totalAssets(), rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return
            (totalShares == 0)
                ? shares.mulDiv(10 ** 18, 10 ** decimals(), rounding)
                : shares.mulDiv(totalAssets(), totalShares, rounding);
    }

    function getUnreleasedAmount() public view returns (uint256) {
        if(releaseAmount == 0) {
            return 0;
        }

        uint256 timeGap = block.timestamp.sub(lastYieldTime);
        // If all vested
        if (timeGap >= releasePeriod) {
            return 0;
        } else {
            uint256 unreleasedAmount = ((releasePeriod.sub(timeGap)).mul(releaseAmount)).div(releasePeriod);
            return unreleasedAmount; 
        }
    }

    function _updateReleaseAmount(uint256 amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount.add(amount); 
        lastYieldTime = block.timestamp; 
    }

    /*    ---------- Write Functions ----------    */
    /**
     * @notice Add Yield(TD) to this contract.
     * Emits a `YieldReceived` event.
     */
    function addYield(uint256 amount, bool negativeGrowth) external {
        require(msg.sender == address(td), "msg.sender must be TD contract");
        require(amount > 0, "Yield amount must > 0");

        uint256 profit;
        if(!negativeGrowth) {
            profit = amount.mul(profitNumerator).div(profitDenominator);
            totalProfit += profit;
            stakedTDAmount = stakedTDAmount.add(amount - profit);
            _updateReleaseAmount(amount - profit);
            ITD(asset()).mintForYield(amount - profit);
            ITD(asset()).mintForProfitRecipient(profitRecipient, profit);
            emit YieldReceived(amount - profit, false);
            emit TransferProfit(profitRecipient, profit);
        } else {
            uint256 remainingAmount = amount;

            // step1: check released amount
            uint256 availableAssets = stakedTDAmount.sub(getUnreleasedAmount());
            uint256 toBurnFromAssets = Math.min(availableAssets, remainingAmount);
            if(toBurnFromAssets > 0) {
                stakedTDAmount = stakedTDAmount.sub(toBurnFromAssets);
                remainingAmount = remainingAmount.sub(toBurnFromAssets);
                ITD(asset()).burnForYield(toBurnFromAssets);
            }

            // step2: check unreleased amount
            if(remainingAmount > 0) {
                uint256 unreleased = getUnreleasedAmount();
                uint256 toBurnFromUnreleased = Math.min(unreleased, remainingAmount);
                
                if(toBurnFromUnreleased > 0) {
                    releaseAmount = releaseAmount.sub(toBurnFromUnreleased);
                    stakedTDAmount = stakedTDAmount.sub(toBurnFromUnreleased);
                    remainingAmount = remainingAmount.sub(toBurnFromUnreleased);
                    ITD(asset()).burnForYield(toBurnFromUnreleased);
                }
            }
            
            emit YieldReceived(amount.sub(remainingAmount), true);
        }
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.mint(shares, receiver);
    }

    /**
     * @dev Add mode check to {IERC4626-withdraw}.
     */
    function withdraw(uint256 assets, address receiver, address user) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.withdraw(assets, receiver, user);
    }

    /**
     * @dev Add mode check to {IERC4626-redeem}.
     */
    function redeem(uint256 shares, address receiver, address user) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.redeem(shares, receiver, user);
    }

    function stake(uint256 assets) external {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod > 0, "ERC4626_MODE_OFF");

        uint256 shares = super.deposit(assets, msg.sender);
        totalShares = totalShares.add(shares);
        emit Stake(assets, shares, msg.sender);
    }

    /**
     * @notice Used to claim USDz after CD has finished.
     * @dev Works on both mode.
     */
    function claim() external {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        UserUnstakingInfo[7] storage userUnstakingInfo = userUnstakingQueue[msg.sender];

        uint256 amountToClaim = 0;
        for(uint256 i = 0; i < userUnstakingInfo.length; ++i) {
            if(block.timestamp >= userUnstakingInfo[i].endTime || unstakingPeriod == 0) {
                amountToClaim += userUnstakingInfo[i].amount;

                userUnstakingInfo[i].endTime = 0;
                userUnstakingInfo[i].amount = 0;
            }
        }

        IStakingVault(stakingVault).sendToUser(msg.sender, amountToClaim);
        emit Claim(amountToClaim, msg.sender);
    }

    /**
     * @notice Starts withdraw CD with shares.
     */
    function unstake(uint256 shares) external returns (uint256 assets) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod > 0, "ERC4626_MODE_OFF");
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }

        assets = previewRedeem(shares);

        UserUnstakingInfo[7] storage userUnstakingInfo = userUnstakingQueue[msg.sender];
        for(uint256 i = 0; i < userUnstakingInfo.length; ++i) {
            if(userUnstakingInfo[i].amount == 0 && userUnstakingInfo[i].endTime == 0) {
                userUnstakingInfo[i].endTime = block.timestamp + unstakingPeriod;
                userUnstakingInfo[i].amount += assets;
                break;
            }
        }

        _withdraw(msg.sender, stakingVault, msg.sender, assets, shares);
        totalShares = totalShares.sub(shares);
        emit UnStake(shares, assets, msg.sender);  
        return assets;  
    }

    /**
     * @dev Add nonReetrant and pooledUSDz calculation.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        require(assets > 0, "ASSETS_IS_ZERO");
        require(shares > 0, "SHARES_IS_ZERO");

        super._deposit(caller, receiver, assets, shares);
        stakedTDAmount = stakedTDAmount.add(assets);
    }

    function _withdraw(address caller, address receiver, address user, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        require(assets > 0, "ASSETS_IS_ZERO");
        require(shares > 0, "SHARES_IS_ZERO");

        stakedTDAmount = stakedTDAmount.sub(assets);
        super._withdraw(caller, receiver, user, assets, shares);
    }

    function rescueERC20(address tokenAddress, address to, uint256 amount) external onlyAdmin {
        require(tokenAddress != address(this), "Can't rescue stTD");
        // If is TD, check pooled amount first.
        if (tokenAddress == asset()) {
            require(amount <= IERC20(tokenAddress).balanceOf(address(this)).sub(stakedTDAmount), "TD rescue amount too large");
        }
        IERC20(tokenAddress).safeTransfer(to, amount);
    }

    function setNewTD(address newTD) external onlyAdmin {
        require(newTD != address(td) && newTD != address(0), "_td address wrong");
        td = IERC20(newTD);
        emit SetNewTD(newTD);
    }

    function setNewStakingVault(address newStakingVault) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(newStakingVault != stakingVault && newStakingVault != address(0), "_stakingVault address wrong");
        stakingVault = newStakingVault;
        emit SetNewStakingVault(newStakingVault);
    }

    function setUnstakingPeriod(uint24 newUnstakingPeriod) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(newUnstakingPeriod < MAX_UNSTAKING_PERIOD, "Should be less than maxUnstakingPeriod");

        unstakingPeriod = newUnstakingPeriod;
        emit SetNewUnstakingPeriod(newUnstakingPeriod);
    }

    function setReleasePeriod(uint24 newReleasePeriod) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }

        uint256 unreleasedAmount = getUnreleasedAmount();
        releasePeriod = newReleasePeriod;
        if(unreleasedAmount != 0) {
            releaseAmount = unreleasedAmount;
            lastYieldTime = block.timestamp;
        }
        emit SetNewReleasePeriod(newReleasePeriod);
    }

    function setProfitRecipient(address newRecipient) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(newRecipient != profitRecipient && newRecipient != address(0), "Wrong address");
        profitRecipient = newRecipient;
        emit SetNewProfitRecipient(newRecipient);
    }

    function setProfitNumerator(uint256 newProfitNumerator) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(newProfitNumerator != profitNumerator, "Wrong profitNumerator");

        profitNumerator = newProfitNumerator;
        emit SetNewProfitNumerator(newProfitNumerator);
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyAdmin {
        _setPeer(eid, peer);
    }

    function setBatchPeers(uint32[] memory eids, bytes32[] memory bytes32Addresses) public onlyAdmin {
        require(eids.length == bytes32Addresses.length, "eid and bytes32Addresses length are not same");
        for(uint256 i = 0; i < eids.length; ++i) {
            _setPeer(eids[i], bytes32Addresses[i]);
        }
    }

    function setOptions(uint128 gasLimit, uint128 msgValue) public onlyAdmin {
        bytes memory newOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, msgValue);
        gasOptions = newOptions;
    }
}