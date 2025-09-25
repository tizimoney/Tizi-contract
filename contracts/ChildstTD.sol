// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    bytes public _options;

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
        authorityControl = IAuthorityControl(_accessAddr);
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

    function _updateReleaseAmount(uint256 _amount) internal {
        uint256 unreleasedAmount = getUnreleasedAmount();
        releaseAmount = unreleasedAmount.add(_amount); 
        lastYieldTime = block.timestamp; 
    }

    /*    ---------- Write Functions ----------    */
    /**
     * @notice Add Yield(TD) to this contract.
     * Emits a `YieldReceived` event.
     */
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

    /**
     * @dev Add mode check to {IERC4626-withdraw}.
     */
    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(unstakingPeriod == 0, "ERC4626_MODE_ON");
        return super.withdraw(assets, receiver, _owner);
    }

    /**
     * @dev Add mode check to {IERC4626-redeem}.
     */
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

    /**
     * @dev Add nonReetrant and pooledUSDz calculation.
     */
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

        releasePeriod = _releasePeriod;
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

    function setPeer(uint32 _eid, bytes32 _peer) public override onlyAdmin {
        _setPeer(_eid, _peer);
    }

    function setBtchPeers(uint32[] memory _eids, bytes32[] memory _peers) public onlyAdmin {
        require(_eids.length == _peers.length, "eid amd peer length are not same");
        for(uint256 i = 0; i < _eids.length; ++i) {
            _setPeer(_eids[i], _peers[i]);
        }
    }

    function setOptions(uint128 GAS_LIMIT, uint128 MSG_VALUE) public onlyAdmin {
        bytes memory new_options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT, MSG_VALUE);
        _options = new_options;
    }
}