// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { ITD } from "./interfaces/ITD.sol";

interface IStakingVault {
    function sendToUser(
        address _to, 
        uint256 _amount
    ) external returns (bool);
}

/**
 * @title Tizi StakedTD
 * @author tizi.money
 * @notice
 *  StakedTD contract allows users to stake TD, using ERC4626 standard.
 *  Each updateYield will mint or burn TD in the contract. The minted 
 *  is not released all at once, but is released linearly over a period
 *  of time. Users need to wait for a cooling period to withdraw TD.
 */
contract StakedTD is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, ERC4626Upgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Max withdraw cd time.
    uint24 public maxUnstakingPeriod;
    uint24 public unstakingPeriod;
    uint256 public releasePeriod;
    uint256 public mainChainId;
    bytes public gasOptions;

    uint256 public stakedTDAmount;
    uint256 public totalShares;
    
    uint256 public releaseAmount;
    uint256 public lastYieldTime;

    address public profitRecipient;
    uint256 public profitNumerator;
    uint256 public profitDenominator;
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

    modifier onlyUpgrader() {
        require(
            _authorityControl.hasRole(
                UPGRADER_ROLE,
                msg.sender
            ),
            "Not authorized"
        );
        _;
    }

    /*    ------------ Constructor ------------    */
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _td, 
        address _stakingVault,
        address _accessAddr,
        address _profitRecipient,
        uint256 _mainChainId
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ERC4626_init(_td);
        __ERC20_init("Staked TD", "stTD");
        __ReentrancyGuard_init();
        

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        td = _td;
        stakingVault = _stakingVault;
        _authorityControl = IAuthorityControl(_accessAddr);
        profitRecipient = _profitRecipient;
        mainChainId = _mainChainId;

        maxUnstakingPeriod = 90 days;
        unstakingPeriod = 604800;
        releasePeriod = 604800;
        profitNumerator = 100;
        profitDenominator = 1000;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyUpgrader
    {}

    /*    ---------- Read Functions -----------    */
    function totalAssets() public view override returns (uint256) {
        uint256 unreleasedAmount = getUnreleasedAmount();
        return stakedTDAmount >= unreleasedAmount ? stakedTDAmount - unreleasedAmount : 0;
    }

    /**
     * @notice ERC4626 and ERC20 define function with same name and parameter types.
     */
    function decimals() public pure override returns (uint8) {
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
     * @notice Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return
            (assets == 0 || totalShares == 0)
                ? assets.mulDiv(10 ** decimals(), 10 ** 18, rounding)
                : assets.mulDiv(totalShares, totalAssets(), rounding);
    }

    /**
     * @notice Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return
            (totalShares == 0)
                ? shares.mulDiv(10 ** 18, 10 ** decimals(), rounding)
                : shares.mulDiv(totalAssets(), totalShares, rounding);
    }

    /// @notice Calculate unreleased TD amount.
    /// @return UnreleasedAmount.
    function getUnreleasedAmount() public view returns (uint256) {
        if(releaseAmount == 0) {
            return 0;
        }

        uint256 timeGap = block.timestamp - lastYieldTime;
        // If all vested
        if (timeGap >= releasePeriod) {
            return 0;
        } else {
            uint256 unreleasedAmount = ((releasePeriod - timeGap) * releaseAmount) / releasePeriod;
            return unreleasedAmount; 
        }
    }

    /// @notice Set new release amount when positive growth.
    /// @param amount New release amount.
    function _updateReleaseAmount(uint256 amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount + amount; 
        lastYieldTime = block.timestamp; 
    }

    /// @notice Set new release amount when negative growth.
    /// @param amount New release amount.
    function _updateNegativeReleaseAmount(uint256 amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount - amount; 
        lastYieldTime = block.timestamp; 
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Called by the TD contract, mint or burn TD in the stake pool.
    /// If it is a positive growth, it will be released linearly and the
    /// release time will be reset. If it is a negative growth, the unreleased
    /// amount will be reduced first, then the released amount will be reduced,
    /// and the release time will be reset.
    function addYield(uint256 amount, bool negativeGrowth) external {
        require(msg.sender == address(td), "msg.sender must be TD contract");
        require(amount > 0, "Yield amount must > 0");

        uint256 profit;
        if(!negativeGrowth) {
            profit = amount * profitNumerator / profitDenominator;
            totalProfit += profit;
            stakedTDAmount = stakedTDAmount + (amount - profit);
            _updateReleaseAmount(amount - profit);
            ITD(asset()).mintForYield(amount - profit);
            ITD(asset()).mintForProfitRecipient(profitRecipient, profit);
            emit YieldReceived(amount - profit, false);
            emit TransferProfit(profitRecipient, profit);
        } else {
            uint256 remainingAmount = amount;

            // step1: check unreleased amount
            if(remainingAmount > 0) {
                uint256 unreleased = getUnreleasedAmount();
                uint256 toBurnFromUnreleased = Math.min(unreleased, remainingAmount);
                
                if(toBurnFromUnreleased > 0) {
                    _updateNegativeReleaseAmount(toBurnFromUnreleased);
                    stakedTDAmount = stakedTDAmount - toBurnFromUnreleased;
                    remainingAmount = remainingAmount - toBurnFromUnreleased;
                    ITD(asset()).burnForYield(toBurnFromUnreleased);
                }
            }

            // step2: check released amount
            if(remainingAmount > 0) {
                uint256 availableAssets = stakedTDAmount - getUnreleasedAmount();
                uint256 toBurnFromAssets = Math.min(availableAssets, remainingAmount);
                if(toBurnFromAssets > 0) {
                    stakedTDAmount = stakedTDAmount - toBurnFromAssets;
                    remainingAmount = remainingAmount - toBurnFromAssets;
                    ITD(asset()).burnForYield(toBurnFromAssets);
                }
            }
            
            emit YieldReceived(amount - remainingAmount, true);
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

    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.redeem(shares, receiver, owner);
    }

    function stake(uint256 assets) external {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod > 0, "ERC4626_MODE_OFF");

        uint256 shares = super.deposit(assets, msg.sender);
        totalShares = totalShares + shares;
        emit Stake(assets, shares, msg.sender);
    }

    /// @notice Used to claim TD after CD has finished.
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
    function unstake(uint256 shares) external returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod > 0, "ERC4626_MODE_OFF");
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);

        UserUnstakingInfo[7] storage userUnstakingInfo = userUnstakingQueue[msg.sender];
        for(uint256 i = 0; i < userUnstakingInfo.length; ++i) {
            if(userUnstakingInfo[i].amount == 0 && userUnstakingInfo[i].endTime == 0) {
                userUnstakingInfo[i].endTime = block.timestamp + unstakingPeriod;
                userUnstakingInfo[i].amount += assets;
                break;
            }
        }

        _withdraw(msg.sender, stakingVault, msg.sender, assets, shares);
        totalShares = totalShares - shares;
        emit UnStake(shares, assets, msg.sender);  
        return assets;  
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        require(assets > 0, "ASSETS_IS_ZERO");
        require(shares > 0, "SHARES_IS_ZERO");

        super._deposit(caller, receiver, assets, shares);
        stakedTDAmount = stakedTDAmount + assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        require(assets > 0, "ASSETS_IS_ZERO");
        require(shares > 0, "SHARES_IS_ZERO");

        stakedTDAmount = stakedTDAmount - assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyAdmin {
        require(token != address(this), "Can't rescue stTD");
        // If is TD, check pooled amount first.
        if (token == asset()) {
            require(amount <= IERC20(token).balanceOf(address(this)) - stakedTDAmount, "TD rescue amount too large");
        }
        IERC20(token).safeTransfer(to, amount);
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
        require(newUnstakingPeriod < maxUnstakingPeriod, "Should be less than maxUnstakingPeriod");

        unstakingPeriod = newUnstakingPeriod;
        emit SetNewUnstakingPeriod(newUnstakingPeriod);
    }

    function setReleasePeriod(uint24 newReleasePeriod) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }

        require(newReleasePeriod <= 60 days, "ReleasePeriod should be less than 60days!");

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
}