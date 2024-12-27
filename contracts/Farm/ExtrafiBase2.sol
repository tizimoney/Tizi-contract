// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ISharedStructs} from "../interfaces/ISharedStructs.sol";

interface ILending {
    function depositAndStake(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external payable returns (uint256 eTokenAmount);

    function unStakeAndWithdraw(
        uint256 reserveId,
        uint256 eTokenAmount,
        address to,
        bool receiveNativeETH
    ) external returns (uint256);
}

interface IStaking {
    function claim() external;

    function balanceOf(address account) external view returns (uint256);

    function lendingPool() external view returns (address);

    function earned(
        address user,
        address rewardToken
    ) external view returns (uint256);
}

interface IPool {
    function exchangeRateOfReserve(
        uint256 reserveId
    ) external view returns (uint256);
}

interface IRouter is ISharedStructs {
    function swap(SwapExecutionParams calldata execution)
        external
        payable
    returns (uint256 returnAmount, uint256 gasUsed);
}

contract ExtrafiBase2 is Ownable, IFarm {
    address public vault;
    address public usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public staking = 0x93d4172b50E82f0fa1C8026782c0ed8Ff39513AF;
    address public extra = 0x2dAD3a13ef0C6366220f989157009e501e7938F8;
    address public lending = 0xBB505c54D71E9e599cB8435b4F0cEEc05fC71cbD;

    uint256 public currentPrincipal = 0;
    uint256 public totalProfit = 0;

    IAuthorityControl private authorityControl;

    event SwapTokenToUSDC(address _token, uint256 _amountOut);

    error USDCnotIncrease();

    /*    ------------ Constructor ------------    */
    constructor(address _vault, address _accessAddr) Ownable(msg.sender) {
        vault = _vault;
        authorityControl = IAuthorityControl(_accessAddr);
    }

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

    /*    ---------- Read Functions -----------    */

    /// @notice Get information about all assets, including quantity, price, 
    /// whether negative growth, whether locked, etc. 
    /// This method is used for rebase. All profits are subject to a certain tax, 
    /// and the amount returned is the amount after tax.
    /// @return Tokeninfo.
    function getTokenInfo()
        external
        view
        override
        returns (TokenInfo[] memory)
    {
        uint256 profitNumerator = IVault(vault).profitNumerator();
        uint256 profitDenominator = IVault(vault).profitDenominator();
        uint256 usdcAfterFee;

        bool negativeInterest = false;
        uint256 _currentProfit = 0;
        uint256 _usdcAmount = getWithdrawableAmount();
        if(currentPrincipal <= _usdcAmount - totalProfit) {
            _currentProfit =  ((_usdcAmount - totalProfit) - currentPrincipal) *
                profitNumerator / profitDenominator;
        } else {
            negativeInterest = true;
            _currentProfit = (currentPrincipal - (_usdcAmount - totalProfit)) *
                profitNumerator / profitDenominator;
        }
        if(negativeInterest) {
            usdcAfterFee = _usdcAmount + _currentProfit - totalProfit;
        } else {
            usdcAfterFee = _usdcAmount - _currentProfit - totalProfit;
        }

        EarlierProfits[] memory checkArray = check();
        CheckInfo[] memory extraInfos = checkArray[1].checkList;
        TokenInfo[] memory tokenInfo = new TokenInfo[](2);

        tokenInfo[0] = TokenInfo({
            tokenAddress: usdc,
            timestamp: 0,
            negativeGrowth: false,
            tokenAmount: (usdcAfterFee +
                IERC20(usdc).balanceOf(address(this))) * 
                (10 ** (18 - IERC20(usdc).decimals())),
            tokenValue: (10 ** 18)
        });

        tokenInfo[1] = TokenInfo({
            tokenAddress: extra,
            timestamp: extraInfos[0].timestamp,
            negativeGrowth: false,
            tokenAmount: (((extraInfos[0].amount *
                (profitDenominator - profitNumerator)) / profitDenominator) +
                IERC20(extra).balanceOf(address(this))) *
                (10 ** (18 - IERC20(extra).decimals())),
            tokenValue: 0
        });
        return tokenInfo;
    }

    /// @notice To obtain information on all assets for dev, 
    /// including principal and profit, the amount shown is accurate, 
    /// the amount is before tax.
    /// @return Tokeninfo.
    function check() public view override returns (EarlierProfits[] memory) {
        EarlierProfits[] memory earlierProfitsList = new EarlierProfits[](2);
        uint256 extraValue = IStaking(staking).earned(address(this), extra);
        uint256 usdcValue = getTotal(24);
        CheckInfo memory usdcInfo = CheckInfo(usdcValue, false, 0);
        earlierProfitsList[0] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[0].checkList[0] = usdcInfo;
        CheckInfo memory extraInfo = CheckInfo(extraValue, false, 0);
        earlierProfitsList[1] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[1].checkList[0] = extraInfo;

        return earlierProfitsList;
    }

    /// @notice Maximum amount that can be withdrawn.
    /// @return Amount.
    function withdrawableAmount() public view returns (uint256) {
        return IERC20(staking).balanceOf(address(this));
    }

    function getTotal(uint256 index) private view returns (uint256) {
        uint256 bal = IStaking(staking).balanceOf(address(this));
        address pool = IStaking(staking).lendingPool();
        uint256 rate = IPool(pool).exchangeRateOfReserve(index);
        uint256 total = bal * rate;
        uint256 convertedTotal = total / 1000000000000000000;
        return convertedTotal;
    }

    /// @notice The amount of unlocked USDC displayed in the Check function.
    /// @return Amount of unlocked USDC.
    function getWithdrawableAmount() public view returns (uint256) {
        EarlierProfits[] memory checkArray = check();
        EarlierProfits memory earlierProfits = checkArray[0];
        CheckInfo[] memory tokenInfo = earlierProfits.checkList;
        uint256 usdcAmount = 0;
        for (uint256 k = 0; k < tokenInfo.length; k++) {
            if (tokenInfo[k].timestamp <= block.timestamp) {
                usdcAmount += tokenInfo[k].amount;
            }
        }
        return usdcAmount;
    }

    function getTokenAddress() public view override returns (address[] memory) {
        address[] memory result = new address[](2);
        result[0] = usdc;
        result[1] = extra;
        return result;
    }

    function getHarvestTokens() public view returns (address[] memory) {
        address[] memory _harvestTokenAddress = new address[](1);
        _harvestTokenAddress[0] = extra;
        return _harvestTokenAddress;
    }

    /*    ---------- Write Functions ----------    */
    function emergencyStop() external override onlyAdmin() {
        require(
            authorityControl.hasRole(
                authorityControl.STRATEGIST_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
        uint256 stakingAmount = IERC20(staking).balanceOf(address(this));
        _withdraw(stakingAmount);
        uint256 amount = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).transfer(vault, amount);
        emit EmergencyStop(msg.sender, vault, amount);
    }

    /// @notice Fees are charged during the deposit or withdrawal process. 
    /// When a normal deposit is made, the tax price will be calculated 
    /// and the value of the principal will be changed. When other tokens are swapped 
    /// for USDC, the deposit will be automatically called, 
    /// and the principal will not be changed at this time, 
    /// which is convenient for collecting taxes on the next deposit.
    /// @param _amount The amount of USDC to start farm.
    /// @param checkPoint Is tax collected.
    function deposit(uint256 _amount, bool checkPoint) public override {
        require(msg.sender == vault || authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ), "sender must be vault or manager");

        if(checkPoint) {
            if (_amount == 0) {
                _amount = IERC20(usdc).balanceOf(address(this));
            }
            require(
                IERC20(usdc).approve(lending, _amount) == true,
                "approve USDC failed"
            );
            require(
                ILending(lending).depositAndStake(
                    24,
                    _amount,
                    address(this),
                    1234
                ) > 0,
                "deposit failed"
            );
        } else {
            uint256 _currentProfit = calCurrentProfit();
            uint256 _usdcAmount = getWithdrawableAmount();
            require(_currentProfit <= _usdcAmount, 
                "current profit is larger than check amount");
            require(totalProfit <= _usdcAmount, 
                "total profit is larger than check amount");

            if (_amount == 0) {
                _amount = IERC20(usdc).balanceOf(address(this));
            }
            require(
                IERC20(usdc).approve(lending, _amount) == true,
                "approve USDC failed"
            );
            require(
                ILending(lending).depositAndStake(
                    24,
                    _amount,
                    address(this),
                    1234
                ) > 0,
                "deposit failed"
            );

            currentPrincipal = _usdcAmount - totalProfit + _amount;
        }
        
        emit Deposit(msg.sender, _amount);
    }

    /// @notice Fees are charged during the deposit or withdrawal process. 
    /// When all USDC is withdrawn at once, totalProfit will be automatically sent to profitRecipient.
    /// @param _amount The amount of USDC to withdraw.
    function withdraw(uint256 _amount) public override returns (uint256) {
        require(msg.sender == vault, "sender must be vault");
        require(_amount <= withdrawableAmount(), 
            "_amount bigger than LP token balance");
        uint256 amountOut = _withdraw(_amount);
        return amountOut;
    }
    
    function _withdraw(uint256 _amount) private returns (uint256) {
        uint256 _currentProfit = calCurrentProfit();
        uint256 _usdcAmount = getWithdrawableAmount();
        require(_currentProfit <= _usdcAmount, 
            "current profit is larger than check amount");
        require(totalProfit <= _usdcAmount, 
            "total profit is larger than check amount");
        require(_usdcAmount >= currentPrincipal, 
            "usdcAmount is smaller than principal");

        uint256 amountOut = ILending(lending).unStakeAndWithdraw(
            24,
            _amount,
            address(this),
            true
        );
        require(amountOut > 0, "withdraw failed");
        require(_currentProfit < amountOut, "fee is too large");
        if(amountOut > _usdcAmount - totalProfit) {
            transferProfit();
            currentPrincipal = 0;
        } else {
            currentPrincipal = _usdcAmount - totalProfit - amountOut;
        }
        emit Withdraw(msg.sender, _amount);
        return amountOut;
    }

    /// @notice Harvest tokens into the contract.
    function harvest() external override {
        require(msg.sender == vault || authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ), "sender must be vault or manager");
        IStaking(staking).claim();
        emit Harvest(msg.sender);
    }

    /// @notice Exchange other tokens into USDC through Kyberswap, 
    /// and automatically deposit the exchanged USDC into the farm.
    function swap(
        address token,
        address router,
        SwapExecutionParams memory request
    ) external override onlyManager() {
        require(token != usdc, "Can not swap USDC");
        uint256 USDCBalBefore = IERC20(usdc).balanceOf(address(this));
        IERC20 tokenContract = IERC20(token);
        uint256 bal = tokenContract.balanceOf(address(this));
        if (bal > 0) {
            require(
                tokenContract.approve(router, bal) == true,
                "approve failed"
            );
            IRouter(router).swap(request);
            emit TokenSwap(bal);

            uint256 USDCBalAfter = IERC20(usdc).balanceOf(address(this));

            if(USDCBalAfter <= USDCBalBefore) {
                revert USDCnotIncrease();
            }

            deposit(USDCBalAfter - USDCBalBefore, true);
            emit SwapTokenToUSDC(token, USDCBalAfter - USDCBalBefore);
        }
    }

    /// @notice Transfer USDC to vault.
    /// @param _amount The amount of USDC to transfer.
    function toVault(uint256 _amount) external override {
        require(msg.sender == vault, "sender must be vault");
        require(IERC20(usdc).balanceOf(address(this)) >= totalProfit,
            "total profit is larger than balance");
        require(IERC20(usdc).balanceOf(address(this)) >= _amount,
            "_amount is larger than balance");
        if(IERC20(usdc).balanceOf(address(this)) >= _amount + totalProfit) {
            IERC20(usdc).transfer(vault, _amount);
            emit ToVault(msg.sender, _amount, vault);
        } else {
            IERC20(usdc).transfer(vault, IERC20(usdc).balanceOf(address(this)) - totalProfit);
            emit ToVault(msg.sender, _amount, vault);
        }
    }

    /// @notice Extract other interference tokens.
    /// @param _token The address of token.  
    function seize(address _token) external override onlyAdmin {
        require(_token != address(0), "invalid address");
        require(_token != usdc && _token != extra, "Invalid token");
        IERC20(_token).transfer(
            msg.sender,
            IERC20(_token).balanceOf(address(this))
        );
        emit Seize(msg.sender, IERC20(_token).balanceOf(address(this)));
    }

    /// @notice Transfer profit to profitRecipient, called by recipient or withdraw function.
    function transferProfit() public {
        address profitRecipient = IVault(vault).profitRecipient();
        require(msg.sender == profitRecipient || msg.sender == vault,
            "Sender must be profitRecipient or vault!");

        require(IERC20(usdc).balanceOf(address(this)) >= totalProfit, 
            "No enough balance for profit");
        IERC20(usdc).transfer(profitRecipient, totalProfit);
        totalProfit = 0;
    }

    /// @notice Calculate the amount of tax collected, taking into account the negative growth situation.
    function calCurrentProfit() private returns (uint256) {
        uint256 profitNumerator = IVault(vault).profitNumerator();
        uint256 profitDenominator = IVault(vault).profitDenominator();
        bool negativeInterest = false;
        uint256 _currentPrincipal = currentPrincipal;
        uint256 _totalProfit = totalProfit;
        uint256 _currentProfit = 0;
        uint256 _usdcAmount = getWithdrawableAmount();
        
        if(_currentPrincipal <= _usdcAmount - _totalProfit) {
            _currentProfit =  ((_usdcAmount - _totalProfit) - _currentPrincipal) *
                profitNumerator / profitDenominator;
        } else {
            negativeInterest = true;
            _currentProfit = (_currentPrincipal - (_usdcAmount - _totalProfit)) *
                profitNumerator / profitDenominator;
        }

        if(!negativeInterest) {
            totalProfit += _currentProfit;
        } else {
            if(_currentProfit > totalProfit) {
                totalProfit = 0;
            } else {
                totalProfit -= _currentProfit;
            }
        }

        return _currentProfit;
    }
}
