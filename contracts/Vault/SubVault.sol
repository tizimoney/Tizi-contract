// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {ISharedStructs} from "../interfaces/ISharedStructs.sol";

interface ITransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool);
}

interface IStakingToken {
    function balanceOf(address) external view returns (uint256);
}

interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64);
}

contract SubVault is ISharedStructs {
    address public profitRecipient;
    uint256 public profitNumerator = 100;
    uint256 public profitDenominator = 1000;
    address public usdcAddr;
    address private swapRouter;
    address public mainVault;
    address public tokenMessenger;

    IAuthorityControl private authorityControl;
    ITransmitter private transmitter;
    IERC20 private usdc;
    IStrategyManager private strategyManager;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _usdcAddr,
        address _transmitter,
        address _swapRouter,
        address _tokenMessenger
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        usdc = IERC20(_usdcAddr);
        usdcAddr = _usdcAddr;
        transmitter = ITransmitter(_transmitter);
        swapRouter = _swapRouter;
        tokenMessenger = _tokenMessenger;
    }

    /*    -------------- Events --------------    */
    event SetFarm(address indexed farm, uint256 indexed chainId);
    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event BridgeInInfo(bytes32 messageHash);
    event SetControl(address newControl);
    event SetSwapRouter(address swapRouter);

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

    /// @notice Call the receiveMessage function of the CCTP transmitter to receive cross-chain USDC.
    /// @param _message The information sent by mainVault.
    /// @param _attestation Attestation from CCTP.
    function bridgeIn(
        bytes calldata _message,
        bytes calldata _attestation
    ) public onlyManager {
        require(
            transmitter.receiveMessage(_message, _attestation) == true,
            "collection failure"
        );
        emit BridgeInInfo(keccak256(_message));
    }

    /// @notice Call CCTP tokenMessenger function to only allow sending to registered vault addresses.
    /// @param _amount The amount of USDC.
    /// @param _destDomain The domain of destination chain.
    /// @param _receiver The address of mainVault.
    function bridgeOut(
        uint256 _amount,
        uint32 _destDomain,
        address _receiver
    ) public onlyManager {
        require(_amount > 0, "Amount must be greater than zero");
        require(_receiver == mainVault, "Receiver is not vault");
        bytes32 receiverBytes32 = addressToBytes32(_receiver);
        require(
            IERC20(usdcAddr).approve(tokenMessenger, _amount) == true,
            "approve fail"
        );
        ITokenMessenger(tokenMessenger).depositForBurn(
            _amount,
            _destDomain,
            receiverBytes32,
            usdcAddr
        );
        emit BridgeToInfo(_destDomain, _receiver, _amount);
    }

    function setMainVault(address _vault) external onlyAdmin {
        require(_vault != address(0) && _vault != mainVault, "Wrong vault address");
        mainVault = _vault;
    }

    function setTokenMessenger(address _tokenMessenger) external onlyAdmin {
        require(_tokenMessenger != address(0) && _tokenMessenger != tokenMessenger, "Wrong messenger address");
        tokenMessenger = _tokenMessenger;
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
        IFarm(_farm).deposit(_amount, false);
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
        uint256 amountOut = IFarm(_farm).withdraw(_amount);
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
        strategyManager = IStrategyManager(_control);
        emit SetControl(_control);
    }

    function setProfitRate(uint256 _rate) public onlyAdmin {
        profitNumerator = _rate;
    }

    function setProfitAccount(address _account) public onlyAdmin {
        profitRecipient = _account;
    }

    function setSwapRouter(address _router) public onlyAdmin {
        swapRouter = _router;
        emit SetSwapRouter(_router);
    }
}
