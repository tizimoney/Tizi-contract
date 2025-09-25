// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenStats} from "./interfaces/ITokenStats.sol";
import {IHelper} from "./interfaces/IHelper.sol";
import {IAuthorityControl} from "./interfaces/IAuthorityControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

interface ISTD {
    function addYield(uint256 _amount, bool negativeGrowth) external;
}

/**
 * @title Tizi TiziDollar
 * @author tizi.money
 * @notice
 *  TiziDollar is a cross-chain stablecoin of Tizi.money. TD is deployed on
 *  multiple chains and supports cross-chain. Cross-chain is supported by
 *  LayerZero. TD can be staked to stTD, TD itself does not generate profit,
 *  users can earn income by staking or participating in other Defi activities.
 * 
 *  TD can only be minted and burned through DepositHelper on the Base chain.
 *  It will not be minted on other chains. As a stablecoin, TD can also
 *  participate in the yield of other stablecoins.
 */
contract TiziDollar is OFT, ERC20Permit {
    using OptionsBuilder for bytes;

    address public helper;
    // insurance pool set up for negative growth
    address public insurancePool;
    uint256 public rebaseNonce;
    uint256 public lastRebaseTime;
    // total assets in project
    uint256 public netAsset;
    address public tokenStats;
    address public sTD;
    uint256 public mainChainId;
    bytes public _options;

    IAuthorityControl private authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _lzEndpoint,
        address _delegate,
        address _access,
        uint256 _mainChainId
    ) 
        OFT("Tizi Dollar", "TD", _lzEndpoint, _delegate) 
        Ownable(_delegate) 
        ERC20Permit("TD")
    {
        authorityControl = IAuthorityControl(_access);
        mainChainId = _mainChainId;
    }

    /*    -------------- Events --------------    */
    event SetHelper(address newHelper);
    event SetTokenStats(address newTokenStats);
    event RebaseAction(
        uint256 oldNetAsset,
        uint256 assetsChange,
        bool negativeGrowth,
        uint256 rebaseTime
    );
    event BurnInsurancePool(
        uint256 indexed amount,
        uint256 indexed rebaseNonce,
        uint256 indexed rebaseTime
    );
    event SendRebaseInfo(uint256 dstChainId, uint256 rebaseIndex);
    event SetNewMainChainID(uint256 chainID);
    event SetNewSTD(address sTD);
    event SetNewInsurancePool(address insurancePool);
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

    /*    ---------- Read Functions -----------    */
    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _b) public pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Mint TD to user, only allowed to DepositHelper.
    /// @param amount The amount to mint.
    /// @param to Receiver.
    function mint(uint256 amount, address to) public {
        require(msg.sender == helper, "Not authorized");
        _mint(amount, to);
        netAsset += amount;
    }

    function _mint(uint256 amount, address to) private {
        require(to != address(0), "Invalid address");
        _update(address(0), to, amount);
    }

    /// @notice Burn TD for user, only allowed to DepositHelper.
    /// @param amount The amount to burn.
    /// @param from TD owner.
    function burn(uint256 amount, address from) public {
        require(msg.sender == helper, "Not authorized");
        _burn(amount, from);
        netAsset -= amount;
    }

    function _burn(uint256 amount, address from) private {
        require(from != address(0), "Invalid address");
        require(balanceOf(from) >= amount, "Invalid amount");
        _update(from, address(0), amount);
    }

    function transfer(
        address to,
        uint value
    ) public override returns (bool) {
        require(to != address(0), "invalid recipient");
        _update(msg.sender, to, value);
        return true;
    }

    function approve(
        address spender,
        uint256 value
    ) public override returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        if (currentAllowance != type(uint256).max) {
            unchecked {
                _approve(msg.sender, spender, currentAllowance + value, true);
            }
        }
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        require(from != address(0), "Invalid sender");
        require(to != address(0), "Invalid receiver");
        require(balanceOf(from) >= value, "Insufficient balance");
        _spendAllowance(from, msg.sender, value);
        _update(from, to, value);
        return true;
    }

    /// @notice Add or burn yield in stake pool, If negative growth occurs, 
    /// the order of burn is InsurancePool->unreleasedAmount->releasedAmount.
    /// set netAssets to netAssets.
    function updateYield() public payable onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }

        uint256 oldNetAsset = netAsset;
        uint256 nftAmount = IHelper(helper).nftQueueUSDC();
        uint256 newNetAsset = ITokenStats(tokenStats).calculateTotalChainValues() - (nftAmount * (10 ** 12));
        require(newNetAsset != oldNetAsset, "no need to rebase");
        rebaseNonce++;
        lastRebaseTime = block.timestamp;

        if(newNetAsset > oldNetAsset) {
            ISTD(sTD).addYield(newNetAsset - oldNetAsset, false);
            emit RebaseAction(oldNetAsset, newNetAsset - oldNetAsset, false, lastRebaseTime);
        } 
        if(newNetAsset < oldNetAsset) {
            uint256 negativeAmount = oldNetAsset - newNetAsset;
            uint256 amountInsurancePool = balanceOf(insurancePool);
            if(amountInsurancePool >= negativeAmount) {
                _burn(negativeAmount, insurancePool);
                emit BurnInsurancePool(negativeAmount, rebaseNonce, lastRebaseTime);
                emit RebaseAction(oldNetAsset, 0, false, lastRebaseTime);
            } else {
                _burn(amountInsurancePool, insurancePool);
                ISTD(sTD).addYield(negativeAmount - amountInsurancePool, true);
                emit BurnInsurancePool(amountInsurancePool, rebaseNonce, lastRebaseTime);
                emit RebaseAction(oldNetAsset, negativeAmount - amountInsurancePool, true, lastRebaseTime);
            }
        }
        
        netAsset = newNetAsset;
    }

    /// @notice Mint TD to stake pool.
    /// @param amount The amount to mint.
    function mintForYield(uint256 amount) external {
        require(msg.sender == sTD, "msg.sender must be sTD contract");
        _mint(amount, sTD);
    }

    /// @notice Burn TD for stake pool.
    /// @param amount The amount to burn.
    function burnForYield(uint256 amount) external {
        require(msg.sender == sTD, "msg.sender must be sTD contract");
        _burn(amount, sTD);
    }

    /// @notice Mint TD for profitRecipient.
    /// @param profitRecipient Receiver address.
    /// @param profit The amount to mint.
    function mintForProfitRecipient(address profitRecipient, uint256 profit) external {
        require(msg.sender == sTD, "msg.sender must be sTD contract");
        _mint(profit, profitRecipient);
    }

    function setHelper(address _helper) public onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(_helper != helper && _helper != address(0), "Wrong address");
        helper = _helper;
        emit SetHelper(_helper);
    }

    function setTokenStats(address _tokenStats) public onlyAdmin {
        require(_tokenStats != tokenStats && _tokenStats != address(0), "Wrong address");
        tokenStats = _tokenStats;
        emit SetTokenStats(_tokenStats);
    }

    function setMainChainId(uint256 _chainid) public onlyAdmin {
        require(_chainid != mainChainId && _chainid != 0, "Wrong chainId");
        mainChainId = _chainid;
        emit SetNewMainChainID(_chainid);
    }

    function setSTD(address _sTD) public onlyAdmin {
        require(_sTD != sTD && _sTD != address(0), "Wrong address");
        sTD = _sTD;
        emit SetNewSTD(_sTD);
    }

    function setInsurancePool(address _insurancePool) public onlyAdmin {
        require(_insurancePool != insurancePool && _insurancePool != address(0), "Wrong address");
        insurancePool = _insurancePool;
        emit SetNewInsurancePool(_insurancePool);
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
