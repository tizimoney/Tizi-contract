// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { ITD } from "./interfaces/ITD.sol";
import "./utils/SafeMath.sol";

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
    using SafeMath for uint256;
    using Math for uint256;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Max withdraw cd time.
    uint24 public MAX_UNSTAKING_PERIOD;
    uint24 public unstakingPeriod;
    uint256 public releasePeriod;
    uint256 public mainChainId;
    bytes public _options;

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
    IAuthorityControl private authorityControl;

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
            authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        _;
    }

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

    modifier onlyUpgrader() {
        require(
            authorityControl.hasRole(
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
        authorityControl = IAuthorityControl(_accessAddr);
        profitRecipient = _profitRecipient;
        mainChainId = _mainChainId;

        MAX_UNSTAKING_PERIOD = 90 days;
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
        return stakedTDAmount >= unreleasedAmount ? stakedTDAmount.sub(unreleasedAmount) : 0;
    }

    /**
     * @notice ERC4626 and ERC20 define function with same name and parameter types.
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _b) public pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    function getUserAllUnstakeInfo(address _user) external view returns (UserUnstakingInfo[7] memory) {
        return userUnstakingQueue[_user];
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

        uint256 timeGap = block.timestamp.sub(lastYieldTime);
        // If all vested
        if (timeGap >= releasePeriod) {
            return 0;
        } else {
            uint256 unreleasedAmount = ((releasePeriod.sub(timeGap)).mul(releaseAmount)).div(releasePeriod);
            return unreleasedAmount; 
        }
    }

    /// @notice Set new release amount when positive growth.
    /// @param _amount New release amount.
    function _updateReleaseAmount(uint256 _amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount.add(_amount); 
        lastYieldTime = block.timestamp; 
    }

    /// @notice Set new release amount when negative growth.
    /// @param _amount New release amount.
    function _updateNegativeReleaseAmount(uint256 _amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount.sub(_amount); 
        lastYieldTime = block.timestamp; 
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Called by the TD contract, mint or burn TD in the stake pool.
    /// If it is a positive growth, it will be released linearly and the
    /// release time will be reset. If it is a negative growth, the unreleased
    /// amount will be reduced first, then the released amount will be reduced,
    /// and the release time will be reset.
    function addYield(uint256 _amount, bool negativeGrowth) external {
        require(msg.sender == address(td), "msg.sender must be TD contract");
        require(_amount > 0, "Yield amount must > 0");

        uint256 profit;
        if(!negativeGrowth) {
            profit = _amount.mul(profitNumerator).div(profitDenominator);
            totalProfit += profit;
            stakedTDAmount = stakedTDAmount.add(_amount - profit);
            _updateReleaseAmount(_amount - profit);
            ITD(asset()).mintForYield(_amount - profit);
            ITD(asset()).mintForProfitRecipient(profitRecipient, profit);
            emit YieldReceived(_amount - profit, false);
            emit TransferProfit(profitRecipient, profit);
        } else {
            uint256 remainingAmount = _amount;

            // step1: check unreleased amount
            if(remainingAmount > 0) {
                uint256 unreleased = getUnreleasedAmount();
                uint256 toBurnFromUnreleased = Math.min(unreleased, remainingAmount);
                
                if(toBurnFromUnreleased > 0) {
                    _updateNegativeReleaseAmount(toBurnFromUnreleased);
                    stakedTDAmount = stakedTDAmount.sub(toBurnFromUnreleased);
                    remainingAmount = remainingAmount.sub(toBurnFromUnreleased);
                    ITD(asset()).burnForYield(toBurnFromUnreleased);
                }
            }

            // step2: check released amount
            if(remainingAmount > 0) {
                uint256 availableAssets = stakedTDAmount.sub(getUnreleasedAmount());
                uint256 toBurnFromAssets = Math.min(availableAssets, remainingAmount);
                if(toBurnFromAssets > 0) {
                    stakedTDAmount = stakedTDAmount.sub(toBurnFromAssets);
                    remainingAmount = remainingAmount.sub(toBurnFromAssets);
                    ITD(asset()).burnForYield(toBurnFromAssets);
                }
            }
            
            emit YieldReceived(_amount.sub(remainingAmount), true);
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

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.redeem(shares, receiver, _owner);
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
    function unstake(uint256 _shares) external returns (uint256 _assets) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod > 0, "ERC4626_MODE_OFF");
        uint256 maxShares = maxRedeem(msg.sender);
        if (_shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, _shares, maxShares);
        }

        _assets = previewRedeem(_shares);

        UserUnstakingInfo[7] storage userUnstakingInfo = userUnstakingQueue[msg.sender];
        for(uint256 i = 0; i < userUnstakingInfo.length; ++i) {
            if(userUnstakingInfo[i].amount == 0 && userUnstakingInfo[i].endTime == 0) {
                userUnstakingInfo[i].endTime = block.timestamp + unstakingPeriod;
                userUnstakingInfo[i].amount += _assets;
                break;
            }
        }

        _withdraw(msg.sender, stakingVault, msg.sender, _assets, _shares);
        totalShares = totalShares.sub(_shares);
        emit UnStake(_shares, _assets, msg.sender);    
    }

    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares)
        internal
        override
        nonReentrant
    {
        require(_assets > 0, "ASSETS_IS_ZERO");
        require(_shares > 0, "SHARES_IS_ZERO");

        super._deposit(_caller, _receiver, _assets, _shares);
        stakedTDAmount = stakedTDAmount.add(_assets);
    }

    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
        nonReentrant
    {
        require(_assets > 0, "ASSETS_IS_ZERO");
        require(_shares > 0, "SHARES_IS_ZERO");

        stakedTDAmount = stakedTDAmount.sub(_assets);
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    function rescueERC20(address _token, address _to, uint256 _amount) external onlyAdmin {
        require(_token != address(this), "Can't rescue stTD");
        // If is TD, check pooled amount first.
        if (_token == asset()) {
            require(_amount <= IERC20(_token).balanceOf(address(this)).sub(stakedTDAmount), "TD rescue amount too large");
        }
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function setNewTD(address _td) external onlyAdmin {
        require(_td != address(td) && _td != address(0), "_td address wrong");
        td = IERC20(_td);
        emit SetNewTD(_td);
    }

    function setNewStakingVault(address _stakingVault) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(_stakingVault != stakingVault && _stakingVault != address(0), "_stakingVault address wrong");
        stakingVault = _stakingVault;
        emit SetNewStakingVault(_stakingVault);
    }

    function setUnstakingPeriod(uint24 _unstakingPeriod) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(_unstakingPeriod < MAX_UNSTAKING_PERIOD, "Should be less than maxUnstakingPeriod");

        unstakingPeriod = _unstakingPeriod;
        emit SetNewUnstakingPeriod(_unstakingPeriod);
    }

    function setReleasePeriod(uint24 _releasePeriod) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }

        uint256 unreleasedAmount = getUnreleasedAmount();
        releasePeriod = _releasePeriod;
        if(unreleasedAmount != 0) {
            releaseAmount = unreleasedAmount;
            lastYieldTime = block.timestamp;
        }
        emit SetNewReleasePeriod(_releasePeriod);
    }

    function setProfitRecipient(address _recipient) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(_recipient != profitRecipient && _recipient != address(0), "Wrong address");
        profitRecipient = _recipient;
        emit SetNewProfitRecipient(_recipient);
    }

    function setProfitNumerator(uint256 _profitNumerator) external onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(_profitNumerator != profitNumerator, "Wrong profitNumerator");

        profitNumerator = _profitNumerator;
        emit SetNewProfitNumerator(_profitNumerator);
    }
}