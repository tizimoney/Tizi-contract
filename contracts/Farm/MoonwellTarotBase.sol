// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ISharedStructs} from "../interfaces/ISharedStructs.sol";

interface IMusdc {
    function exchangeRateStored() external view returns (uint);
    function getAccountSnapshot(address account) 
        external view 
    returns (uint, uint, uint, uint);
    function mint(uint mintAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
}

interface IMweth {
    function borrow(uint borrowAmount) external returns (uint);
}

interface IComptroller {
    function rewardDistributor() external view returns (address);
    function enterMarkets(address[] memory mTokens) external returns (uint[] memory);
    function claimReward(address holder, address[] memory mTokens) external;
    function getAccountLiquidity(address account) external view returns (uint, uint, uint);
}

interface IMultiRewardDistributor {
    struct RewardInfo{
        address emissionToken;
        uint totalAmount;
        uint supplySide;
        uint borrowSide;
    }

    struct RewardWithMToken {
        address mToken;
        RewardInfo[] rewards;
    }

    function getOutstandingRewardsForUser(
        address _user
    ) external view returns (RewardWithMToken[] memory);
}

interface IFactory {
    struct RewardInfo {
      address towerPool;
      address rewardTokenAddress;
      string rewardTokenSymbol;
      uint256 rewardTokenDecimals;
      uint256 periodFinish;
      uint256 rewardRate;
      uint256 lastUpdateTime;
      uint256 rewardPerTokenStored;
      uint256 pendingReward;
      uint256 reinvestBounty;
      bool isStarted;
    }

    struct TowerPoolInfo {
      address towerPool;
      address tokenForTowerPool;
      RewardInfo[] rewardInfoList;
      uint256 totalSupply;
      uint256 accountBalance;
      uint256[] earnedList;
    }

    function getInfoForAllTowerPools(address account) 
        external view 
    returns (TowerPoolInfo[] memory towerPoolInfoList);

    function claimRewards(
        address[] memory _towerPools,
        address[][] memory _tokens
    ) external;
}

interface IBtarot {
    function exchangeRateLast() external view returns (uint256);
}

interface IWeth {
    function withdraw(uint wad) external;
    function deposit() external payable;
}

interface IDepositRouter {
    function mint(
        address poolToken,
        uint256 amount,
        address to,
        uint256 deadline
    ) external returns (uint256 tokens);

    function mintETH(
        address poolToken,
        address to,
        uint256 deadline
    )external payable returns (uint256 tokens);

    function redeem(
        address poolToken,
        uint256 tokens,
        address to,
        uint256 deadline,
        bytes memory permitData
    ) external returns (uint256 amount);

    function redeemETH(
        address poolToken,
        uint256 tokens,
        address to,
        uint256 deadline,
        bytes memory permitData
    ) external returns (uint256 amountETH);
}

interface IRepayRouter {
    function repayBorrowBehalf(address borrower) external payable;
}

interface ITower {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
}

interface IRouter is ISharedStructs {
    function swap(SwapExecutionParams calldata execution)
        external
        payable
    returns (uint256 returnAmount, uint256 gasUsed);
}

contract MoonwellTarotBase is IFarm {
    address public vault;
    address private usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private comptroller = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    address private mweth = 0x628ff693426583D9a7FB391E54366292F509D457;
    address private musdc = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address private factory = 0xB0d74D24Ae94985c614A52d79d1BDEc0A6F57bEE;
    address private weth = 0x4200000000000000000000000000000000000006;
    address private well = 0xA88594D404727625A9437C3f886C7643872296AE;
    address private depositRouter = 0xD7cABeF2c1fD77a31c5ba97C724B82d3e25fC83C;
    address private repayRouter = 0x70778cfcFC475c7eA0f24cC625Baf6EaE475D0c9;
    address private withdrawRouter = 0xD7cABeF2c1fD77a31c5ba97C724B82d3e25fC83C;

    address private ethFeed = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address private usdcFeed = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    uint256 public currentPrincipal = 0;
    uint256 public totalProfit = 0;

    address[] public allowlist;

    IAuthorityControl private authorityControl;

    event SwapTokenToUSDC(address _token, uint256 _amountOut);

    error USDCnotIncrease();

    /*    ------------ Constructor ------------    */
    constructor(address _vault, address _accessAddr) {
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
   
    /*    ---------- Read Functions -----------    */
    function getDerivedPrice(
        address _token,
        address _usdc,
        uint8 _decimals
    ) private view returns (int256) {
        require(
            _decimals > uint8(0) && _decimals <= uint8(18),
            "Invalid _decimals"
        );
        int256 decimals = int256(10 ** uint256(_decimals));
        (, int256 tokenPrice, , , ) = AggregatorV3Interface(_token)
            .latestRoundData();
        uint8 opDecimals = AggregatorV3Interface(_token).decimals();
        tokenPrice = scalePrice(tokenPrice, opDecimals, _decimals);

        (, int256 usdcPrice, , , ) = AggregatorV3Interface(_usdc)
            .latestRoundData();
        uint8 usdcDecimals = AggregatorV3Interface(_usdc).decimals();
        usdcPrice = scalePrice(usdcPrice, usdcDecimals, _decimals);

        return (tokenPrice * decimals) / usdcPrice;
    }

    function scalePrice(
        int256 _price,
        uint8 _priceDecimals,
        uint8 _decimals
    ) private pure returns (int256) {
        if (_priceDecimals < _decimals) {
            return _price * int256(10 ** uint256(_decimals - _priceDecimals));
        } else if (_priceDecimals > _decimals) {
            return _price / int256(10 ** uint256(_priceDecimals - _decimals));
        }
        return _price;
    }

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
        CheckInfo[] memory ethInfos = checkArray[1].checkList;
        CheckInfo[] memory wellInfos = checkArray[2].checkList;
        TokenInfo[] memory tokenInfo = new TokenInfo[](3);

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
            tokenAddress: address(0),
            timestamp: ethInfos[0].timestamp,
            negativeGrowth: ethInfos[0].negativeGrowth,
            tokenAmount: ((ethInfos[0].amount *
                (profitDenominator - profitNumerator)) / profitDenominator),
            tokenValue: uint256(getDerivedPrice(ethFeed, usdcFeed, 18))
        });

        tokenInfo[2] = TokenInfo({
            tokenAddress: well,
            timestamp: wellInfos[0].timestamp,
            negativeGrowth: false,
            tokenAmount: ((wellInfos[0].amount *
                (profitDenominator - profitNumerator)) / profitDenominator) +
                IERC20(well).balanceOf(address(this)) *
                (10 ** (18 - IERC20(well).decimals())),
            tokenValue: 0
        });
        return tokenInfo;
    }

    /// @notice To obtain information on all assets for dev, 
    /// including principal and profit, the amount shown is accurate, 
    /// the amount is before tax.
    /// @return Tokeninfo.
    function check() public view override returns (EarlierProfits[] memory) {
        // 1. Moonwell -- direct supply and borrow
        (uint256 mw_usdc_supply, uint256 mw_eth_borrow) = check1();

        // 2. Moonwell -- reward tokens (WELL and USDC)
        (uint256 mw_usdc_rewards, uint256 mw_well_rewards) = check2();

        // 3. Tarot
        uint256 tarot_eth_supply = check3();

        EarlierProfits[] memory earlierProfitsList = new EarlierProfits[](3);
        CheckInfo memory usdcInfo = CheckInfo(mw_usdc_supply + mw_usdc_rewards, false, 0);
        earlierProfitsList[0] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[0].checkList[0] = usdcInfo;
        CheckInfo memory ethInfo = CheckInfo(
            tarot_eth_supply + address(this).balance >= mw_eth_borrow ? (tarot_eth_supply + address(this).balance) - mw_eth_borrow : mw_eth_borrow - (tarot_eth_supply + address(this).balance),
            tarot_eth_supply + address(this).balance >= mw_eth_borrow ? false : true,
            0
        );
        earlierProfitsList[1] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[1].checkList[0] = ethInfo;
        CheckInfo memory wellInfo = CheckInfo(mw_well_rewards, false, 0);
        earlierProfitsList[2] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[2].checkList[0] = wellInfo;
        return earlierProfitsList;
    }

    function check1() internal view returns (uint256, uint256) {
        // uint rate_mwu = IMusdc(musdc).exchangeRateStored();
        ( , uint supply, , uint rate_mwu) = IMusdc(musdc).getAccountSnapshot(address(this));
        (, , uint borrowBalance, ) = IMusdc(mweth).getAccountSnapshot(address(this));
        uint256 mw_usdc_supply = uint256(supply * rate_mwu) / 1000000000000000000;
        uint256 mw_eth_borrow = uint256(borrowBalance);
        return (mw_usdc_supply, mw_eth_borrow);
    }
    
    function check2() internal view returns (uint256, uint256) {
        uint256 mw_usdc_rewards = 0;
        uint256 mw_well_rewards = 0;
        address reward_dist = IComptroller(comptroller).rewardDistributor();
        IMultiRewardDistributor.RewardWithMToken[] memory mw_rewards = 
            IMultiRewardDistributor(reward_dist).getOutstandingRewardsForUser(address(this));
        for(uint256 i = 0; i < mw_rewards.length; ++i) {
            IMultiRewardDistributor.RewardInfo[] memory rew = mw_rewards[i].rewards;
            for(uint256 j = 0; j < rew.length; ++j) {
                // IMultiRewardDistributor.RewardInfo memory rr = rew[j];
                if(rew[j].totalAmount > 0) {
                    if(rew[j].emissionToken == usdc) {
                        mw_usdc_rewards += uint256(rew[j].totalAmount);
                    } else if(rew[j].emissionToken == well) {
                        mw_well_rewards += uint256(rew[j].totalAmount);
                    }
                }
            }
        }

        return (mw_usdc_rewards, mw_well_rewards);
    }

    function check3() internal view returns (uint256) {
        uint256 tarot_eth_supply = 0;
        for(uint256 i = 0; i < allowlist.length; ++i) {
            address tarot_address = allowlist[i];
            uint256 tarot_balance = IERC20(tarot_address).balanceOf(address(this));

            if(tarot_balance > 0) {
                uint256 rate = IBtarot(tarot_address).exchangeRateLast();
                uint256 value = rate * tarot_balance / 1000000000000000000;
                tarot_eth_supply += value;
            }
        }

        return tarot_eth_supply;
    }

    /// @notice Check whether the pool allows farm.
    /// @param _btarot The address of tarot pool.
    function addressIsAllowed(address _btarot) public view returns (bool) {
        for(uint256 i = 0; i < allowlist.length; ++i) {
            if(allowlist[i] == _btarot) {
                return true;
            }
        }
        return false;
    }

    /// @notice Maximum amount that can be withdrawn.
    /// @return Amount.
    function withdrawableAmount() public view returns (uint256) {
        return IERC20(musdc).balanceOf(address(this));
    }

    /// @notice Get the price you need to repay.
    /// @return Amount.
    function getRepayAmount() public view returns (uint256) {
        (, uint256 borrowAmount) = check1();
        return borrowAmount;
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

    function getTokenAddress() public view override returns (address[] memory) {}

    /*    ---------- Write Functions ----------    */
    function emergencyStop() external override {}

    /// @notice Let USDC deposits can be used as collateral, only need to be called once.
    function init() external onlyManager() {
        address[] memory collateral = new address[](1);
        collateral[0] = musdc;
        IComptroller(comptroller).enterMarkets(collateral);
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
                IERC20(usdc).approve(musdc, _amount) == true,
                "approve USDC failed"
            );
            IMusdc(musdc).mint(_amount);
        } else {
            uint256 _currentProfit = calCurrentProfit();
            uint256 _usdcAmount = getWithdrawableAmount();
            require(_currentProfit <= _usdcAmount);
            require(totalProfit <= _usdcAmount);

            if (_amount == 0) {
                _amount = IERC20(usdc).balanceOf(address(this));
            }
            require(
                IERC20(usdc).approve(musdc, _amount) == true,
                "approve USDC failed"
            );
            IMusdc(musdc).mint(_amount);

            currentPrincipal = _usdcAmount - totalProfit + _amount;
        }
        emit Deposit(msg.sender, _amount);
    }
   
    /// @notice Deposit a certain amount of ETH into the tarot pool.
    /// @param btarot The address of tarot pool.
    /// @param _amount The amount of ETH.
    function deposit2(address btarot, uint256 _amount) public onlyManager {
        require(addressIsAllowed(btarot), "Specified market is not whitelisted");
        if(_amount == 0) {
            _amount = address(this).balance;
        }

        // supply ETH into lending market to get bTAROT
        uint256 timeOut = block.timestamp + 3600;
        IDepositRouter(depositRouter).mintETH{value: _amount}(btarot, address(this), timeOut);
    }

    /// @notice Borrow ETH from Moonwell.
    function borrow(uint256 _amount) public onlyManager {
        IMweth(mweth).borrow(_amount);
    }
    
    /// @notice repay ETH to Moonwell.
    function repay(uint256 _amount) public onlyManager {
        require(_amount <= getRepayAmount());
        IRepayRouter(repayRouter).repayBorrowBehalf{value: _amount}(address(this));
    }
    
    /// @notice Fees are charged during the deposit or withdrawal process. 
    /// When all USDC is withdrawn at once, totalProfit will be automatically sent to profitRecipient.
    /// @param _amount The amount of USDC to withdraw.
    function withdraw(uint256 _amount) public override returns (uint256){
        require(msg.sender == vault || authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ), "sender must be vault or manager");
        require(_amount <= withdrawableAmount(), "_amount bigger than LP token balance");

        uint256 _currentProfit = calCurrentProfit();
        uint256 _usdcAmount = getWithdrawableAmount();
        require(_currentProfit <= _usdcAmount, 
            "current profit is larger than check amount");
        require(totalProfit <= _usdcAmount, 
            "total profit is larger than check amount");
        require(_usdcAmount >= currentPrincipal, 
            "usdcAmount is smaller than principal");

        require(IERC20(musdc).approve(musdc, _amount) == true);
        uint256 usdc_before = IERC20(usdc).balanceOf(address(this));
        IMusdc(musdc).redeem(_amount);
        uint256 usdc_after = IERC20(usdc).balanceOf(address(this));
        uint256 amountOut = usdc_after - usdc_before;

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

    /// @notice Withdraw ETH from tarot pool, but in WETH.
    /// @param _btarot The address of tarot pool.
    /// @param _amount The amount of ETH to withdraw.
    function withdraw2(address _btarot, uint256 _amount) public onlyManager {
        require(
            IERC20(_btarot).approve(withdrawRouter, _amount) == true,
            "approve btarot token failed"
        );
        uint256 btarotBalance = IERC20(_btarot).balanceOf(address(this));
        require(btarotBalance > 0, "No bTAROT tokens, check status of supply tx");

        if(_amount == 0) {
            _amount = btarotBalance;
        }

        uint256 timeOut = block.timestamp + 3600;
        IDepositRouter(withdrawRouter).redeemETH(
            _btarot, _amount, address(this), timeOut, ""
        );
    }
    
    /// @notice Harvest tokens into the contract.
    function harvest() external override {
        require(msg.sender == vault || authorityControl.hasRole(
                authorityControl.MANAGER_ROLE(),
                msg.sender
            ), "sender must be vault or manager");
        uint256 usdc_before = IERC20(usdc).balanceOf(address(this));
        address[] memory mTokens = new address[](2);
        mTokens[0] = mweth;
        mTokens[1] = musdc;
        IComptroller(comptroller).claimReward(address(this), mTokens);
        uint256 usdc_after = IERC20(usdc).balanceOf(address(this));
        uint256 usdc_harvest = usdc_after - usdc_before;
    
        if(usdc_harvest > 0) {
            deposit(usdc_harvest, true);
        }
        emit Harvest(msg.sender);
    }

    /// @notice Exchange other tokens into USDC through Kyberswap, 
    /// and automatically deposit the exchanged USDC into the farm,
    /// Allows other tokens to be swapped for WETH, and WETH will be swapped for ETH.
    function swap(
        address token,
        address router,
        SwapExecutionParams memory request
    ) external override onlyManager() {
        require(token != usdc, "Can not swap USDC");
        uint256 USDCBalBefore = IERC20(usdc).balanceOf(address(this));
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
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
            uint256 wethAfter = IERC20(weth).balanceOf(address(this));

            if(USDCBalAfter <= USDCBalBefore && wethAfter <= wethBefore) {
                revert USDCnotIncrease();
            }

            if(USDCBalAfter > USDCBalBefore) {
                deposit(USDCBalAfter - USDCBalBefore, true);
            } else if(wethAfter > wethBefore) {
                IWeth(weth).withdraw(wethAfter - wethBefore);
            }

            emit SwapTokenToUSDC(token, USDCBalAfter - USDCBalBefore);
        }
    }

    /// @notice Add new tarot pools.
    function addNewMarket(address[] memory _market) public onlyManager returns (address[] memory) {
        for(uint i = 0; i < _market.length; ++i) {
            if(addressIsAllowed(_market[i]) == false) {
                allowlist.push(_market[i]);
            }
        }

        return allowlist;
    }

    /// @notice Exchange ETH to WETH to exchange ETH to USDC.
    function transferWeth() public onlyManager {
        uint256 ethBalance = address(this).balance;
        IWeth(weth).deposit{value: ethBalance}();
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

    function seize(address _token) external override {}

    /// @notice Transfer profit to profitRecipient, called by recipient or withdraw function.
    function transferProfit() public {
        address profitRecipient = IVault(vault).profitRecipient();
        require(msg.sender == profitRecipient || msg.sender == vault || 
            authorityControl.hasRole(authorityControl.MANAGER_ROLE(),msg.sender),
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

    fallback() external payable{}
    receive() external payable {}
}