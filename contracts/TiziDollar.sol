// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ITokenStats } from "./interfaces/ITokenStats.sol";
import { IHelper } from "./interfaces/IHelper.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
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
    bytes public gasOptions;

    IAuthorityControl private _authorityControl;

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
        _authorityControl = IAuthorityControl(_access);
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
    event SetNewMainChainID(uint256 chainID);
    event SetNewSTD(address sTD);
    event SetNewInsurancePool(address insurancePool);
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

    /*    ---------- Read Functions -----------    */
    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function bytes32ToAddress(bytes32 bytes32Address) public pure returns (address) {
        return address(uint160(uint256(bytes32Address)));
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

    function setHelper(address newHelper) public onlyAdmin {
        if (block.chainid != mainChainId) {
            revert UnsupportedChain(block.chainid);
        }
        require(newHelper != helper && newHelper != address(0), "Wrong address");
        helper = newHelper;
        emit SetHelper(newHelper);
    }

    function setTokenStats(address newTokenStats) public onlyAdmin {
        require(newTokenStats != tokenStats && newTokenStats != address(0), "Wrong address");
        tokenStats = newTokenStats;
        emit SetTokenStats(newTokenStats);
    }

    function setMainChainId(uint256 newChainId) public onlyAdmin {
        require(newChainId != mainChainId && newChainId != 0, "Wrong chainId");
        mainChainId = newChainId;
        emit SetNewMainChainID(newChainId);
    }

    function setSTD(address newSTD) public onlyAdmin {
        require(newSTD != sTD && newSTD != address(0), "Wrong address");
        sTD = newSTD;
        emit SetNewSTD(newSTD);
    }

    function setInsurancePool(address newInsurancePool) public onlyAdmin {
        require(newInsurancePool != insurancePool && newInsurancePool != address(0), "Wrong address");
        insurancePool = newInsurancePool;
        emit SetNewInsurancePool(newInsurancePool);
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
