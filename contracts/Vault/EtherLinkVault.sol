// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";

interface IWrappedTokenBridge {
    struct CallParams {
        address payable refundAddress;
        address zroPaymentAddress;
    }

    function estimateBridgeFee(
        uint16 remoteChainId, 
        bool useZro, 
        bytes calldata adapterParams
    ) external view returns (uint nativeFee, uint zroFee);

    function bridge(
        address localToken, 
        uint16 remoteChainId, 
        uint amount, 
        address to, 
        bool unwrapWeth, 
        CallParams calldata callParams, 
        bytes memory adapterParams
    ) external payable;
}

/**
 * @title Tizi EtherLinkVault
 * @author tizi.money
 * @notice
 *  EtherLinkVault is a vault contract deployed on the EtherLink chain. 
 *  Since CCTP does not support the EtherLink chain, LayerZeroV1 is used
 *  for USDC cross-chain, and then the Manager decides
 *  which strategies to store USDC in. You cannot withdraw money in EtherLinkVault,
 *  and USDC will eventually be transferred to the Base chain via LayerZeroV1.
 * 
 *  Only one MainVault supports transfers, and the management and changes
 *  of MainVault are determined by the Admin.
 * 
 *  EtherLinkVault determines the deposits, withdrawals, and harvests of the
 *  current chain's strategy, is managed by the Manager, and can view the
 *  asset information in the strategy.
 */
contract EtherLinkVault {
    address public usdc;
    address public mainVault;
    address public wrappedTokenBridge;
    bytes public options;

    IAuthorityControl private authorityControl;
    IStrategyManager private strategyManager;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _usdc,
        address _wrappedTokenBridge
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        usdc = _usdc;
        wrappedTokenBridge = _wrappedTokenBridge;
        setOptions(1, 125000);
    }

    /*    -------------- Events --------------    */
    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event SetControl(address newControl);

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
    /// @notice Check information about tokens in a strategy, only the current chain is allowed.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    /// @return Tokens info.
    function check(uint256 _chainId, address _farm) public view returns (IFarm.EarlierProfits[] memory) {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm.EarlierProfits[] memory checkArray = IFarm(_farm).check();
        return checkArray;
    }

    function withdrawableAmount(uint256 _chainId, address _farm) external view returns (uint256) {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        uint256 maxAmount = IFarm(_farm).withdrawableAmount();
        return maxAmount;
    }

    function addressToBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Calculate transfer native fee of LayerZeroV1.
    /// @return Native token fee.
    function getTransferFee() public view returns (uint256) {
        (uint256 nativeFee, ) = IWrappedTokenBridge(wrappedTokenBridge).estimateBridgeFee(184, false, options);
        return nativeFee;
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Call WrappedTokenBridge contract to transfer USDC to Base.
    /// @param _amount The amount of USDC.
    function bridgeOut(
        uint256 _amount
    ) public payable onlyManager {
        if(_amount == 0 || _amount > IERC20(usdc).balanceOf(address(this))) {
            _amount = IERC20(usdc).balanceOf(address(this));
        }
        IERC20(usdc).approve(wrappedTokenBridge, _amount);

        IWrappedTokenBridge.CallParams memory callParams = IWrappedTokenBridge.CallParams({
            refundAddress: payable(address(this)),
            zroPaymentAddress: address(0)
        });
        IWrappedTokenBridge(wrappedTokenBridge).bridge{value: msg.value}(
            usdc, 
            184, 
            _amount, 
            mainVault, 
            false, 
            callParams, 
            options
        );
        emit BridgeToInfo(184, mainVault, _amount);
    }

    function setOptions(uint16 _version, uint256 _value) public onlyAdmin {
        options = abi.encodePacked(_version, _value);
    }

    function setMainVault(address _vault) external onlyAdmin {
        require(_vault != address(0) && _vault != mainVault, "Wrong vault address");
        mainVault = _vault;
    }

    function setWrappedTokenBridge(address _wrappedTokenBridge) external onlyAdmin {
        require(_wrappedTokenBridge != address(0) && _wrappedTokenBridge != wrappedTokenBridge, "Wrong address");
        wrappedTokenBridge = _wrappedTokenBridge;
    }

    /// @notice Transfer USDC from strategy to vault.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    /// @param _amount The amount of USDC.
    function exitFarm(uint256 _chainId, address _farm, uint256 _amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        if (_amount == 0) {
            _amount = IERC20(usdc).balanceOf(_farm);
            require(_amount > 0, "Amount must be greater than zero");
        }
        IFarm(_farm).toVault(_amount);
        emit TrasferDetails(_farm, address(this), _amount);
    }

    /// @notice Transfer USDC from vault to strategy.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    /// @param _amount The amount of USDC.
    function enterFarm(uint256 _chainId, address _farm, uint256 _amount) public onlyManager returns (bool) {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        require(_amount > 0, "Amount must be greater than zero");
        require(IERC20(usdc).transfer(_farm, _amount) == true, "transfer failure");
        emit TrasferDetails(address(this), _farm, _amount);
        return true;
    }

    /// @notice Call deposit function in strategy, start to farm.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    /// @param _amount The amount of USDC.
    function deposit(uint256 _chainId, address _farm, uint256 _amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        require(
            IERC20(usdc).balanceOf(_farm) >= _amount,
            "farm balance insufficient"
        );
        IFarm(_farm).deposit(_amount);
    }

    /// @notice Call withdraw function in strategy, withdraw a certain amount of USDC to strategy contract.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    /// @param _amount The amount of USDC.
    function withdraw(uint256 _chainId, address _farm, uint256 _amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm(_farm).withdraw(_amount);
    }

    /// @notice Call harvest function in strategy, withdraw additional tokens to strategy contract.
    /// @param _chainId The chain id where the strategy is located.
    /// @param _farm The address of strategy.
    function harvest(uint256 _chainId, address _farm) public onlyManager {
        require(
            strategyManager.isStrategyActive(_chainId, _farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm(_farm).harvest();
    }

    function setControl(address _control) public onlyAdmin {
        require(_control != address(strategyManager) && _control != address(0), "Wrong address");
        strategyManager = IStrategyManager(_control);
        emit SetControl(_control);
    }

    fallback() external payable{}
    receive() external payable {}
}
