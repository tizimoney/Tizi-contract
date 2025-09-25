// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {ISharedStructs} from "../interfaces/ISharedStructs.sol";

interface IIbc {
    function transferWithDefaultTimeout(string memory toAddress, string memory port, string memory channel, string memory denom, uint256 amount, string memory memo)
        external payable returns (bool success);
}

/**
 * @title Tizi SeiVault
 * @author tizi.money
 * @notice
 *  SeiVault is the Vault contract on the Sei chain used in the past.
 *  Since CCTP does not yet support the Sei chain, CCTP is used to
 *  cross-chain USDC from the Base chain to the Noble chain, and then
 *  IBC is used to cross-chain to the Sei chain.
 */
contract SeiVault is ISharedStructs {
    string private nobleAddress;
    address private ibcRouter;
    string public port;
    string public channel;
    string public denom;
    string public memo;

    IAuthorityControl private authorityControl;
    IERC20 private usdc;
    IStrategyManager private strategyManager;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _usdcAddr,
        string memory _nobleAddress,
        address _ibcRouter,
        string memory _port,
        string memory _channel,
        string memory _denom,
        string memory _memo
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        usdc = IERC20(_usdcAddr);
        nobleAddress = _nobleAddress;
        ibcRouter = _ibcRouter;
        port = _port;
        channel = _channel;
        denom = _denom;
        memo = _memo;
    }

    /*    -------------- Events --------------    */
    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event IBCBridge(string to, uint256 amount);
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
        bytes32 result;
        assembly {
            result := addr
        }
        return result;
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Use IBC transfer USDC to noble chain.
    function bridgeOut(
        uint256 _amount
    ) public onlyManager returns (bool) {
        require(_amount > 0, "Amount must be greater than zero");
        require(
            usdc.approve(ibcRouter, _amount) == true,
            "approve fail"
        );
        bool sueecss = IIbc(ibcRouter).transferWithDefaultTimeout(nobleAddress, port, channel, denom, _amount, memo);
        emit IBCBridge(nobleAddress, _amount);
        return sueecss;
    }

    function setIBCRouter(address _ibcRouter) external onlyAdmin {
        require(_ibcRouter != address(0) && _ibcRouter != ibcRouter, "Wrong messenger address");
        ibcRouter = _ibcRouter;
    }

    function setNobleAddress(string memory _nobleAddress) external onlyAdmin {
        nobleAddress = _nobleAddress;
    }

    function setChannel(string memory _channel) external onlyAdmin {
        channel = _channel;
    }

    function setPort(string memory _port) external onlyAdmin {
        port = _port;
    }

    function setDenom(string memory _denom) external onlyAdmin {
        denom = _denom;
    }

    function setMemo(string memory _memo) external onlyAdmin {
        memo = _memo;
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
            _amount = usdc.balanceOf(_farm);
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
        require(usdc.transfer(_farm, _amount) == true, "transfer failure");
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
            usdc.balanceOf(_farm) >= _amount,
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
}
