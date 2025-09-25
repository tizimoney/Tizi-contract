// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {ISharedStructs} from "../interfaces/ISharedStructs.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64);
}

interface ITransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool);
}

/**
 * @title Tizi MainVault
 * @author tizi.money
 * @notice
 *  MainVault is deployed on the Base chain and is where USDC is first stored.
 *  All user deposits will first be stored in MainVault, and then allocated by
 *  Manager to vaults on other chains or strategies on the Base chain. Funds
 *  cannot be transferred to other places. Users withdraw money from MainVault,
 *  and funds on other chains are also sent to MainVault.
 * 
 *  MainVault sends USDC to vaults on other chains through CCTP. Only vault
 *  addresses stored in vaultAddress allow transfers.
 * 
 *  MainVault determines the deposits, withdrawals, and harvests of the
 *  current chain's strategy, which is managed by Manager, and the asset
 *  information in the strategy can be viewed.
 */
contract MainVault is ISharedStructs, ReentrancyGuard {
    address public helperAddr;
    address public tokenMessenger;

    /// (vault address => is allowed to transfer though CCTP)
    mapping(address => bool) public vaultAddress;

    IAuthorityControl private authorityControl;
    IStrategyManager private strategyManager;
    IERC20 private usdc;
    ITransmitter private transmitter;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _transmitter,
        address _tokenMessenger,
        address _usdc
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        usdc = IERC20(_usdc);
        transmitter = ITransmitter(_transmitter);
        tokenMessenger = _tokenMessenger;
    }

    /*    -------------- Events --------------    */
    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event BridgeInInfo(bytes32 messageHash);
    event SetControl(address newControl);
    event SetHelper(address newHelper);

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

    function addressToBytes32(address addr) private pure returns (bytes32) {
        bytes32 result;
        assembly {
            result := addr
        }
        return result;
    }

    /*    ---------- Write Functions ----------    */

    /// @notice Call CCTP tokenMessenger function to only allow sending to registered vault addresses.
    /// @param _amount The amount of USDC.
    /// @param _destDomain The domain of destination chain.
    /// @param _receiver The address of subVault.
    function bridgeOut(
        uint256 _amount,
        uint32 _destDomain,
        address _receiver
    ) public onlyManager {
        require(_amount > 0, "Amount must be greater than zero");
        require(vaultAddress[_receiver] == true, "Receiver is not vault");
        bytes32 receiverBytes32 = addressToBytes32(_receiver);
        require(
            usdc.approve(tokenMessenger, _amount) == true,
            "approve fail"
        );
        ITokenMessenger(tokenMessenger).depositForBurn(
            _amount,
            _destDomain,
            receiverBytes32,
            address(usdc)
        );
        emit BridgeToInfo(_destDomain, _receiver, _amount);
    }

    /// @notice Call the receiveMessage function of the CCTP transmitter to receive cross-chain USDC.
    /// @param _message The information sent by subVault.
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

    function setVault(address[] memory _vault) external onlyAdmin {
        require(_vault.length > 0, "Please input at least one address");

        for(uint i = 0; i < _vault.length; ++i) {
            require(_vault[i] != address(0), "Wrong vault address");
            vaultAddress[_vault[i]] = true;
        }
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

    /// @notice Only used in mainvault, sent to the user when someone withdraws money.
    /// @param _to Receiver address.
    /// @param _amount The amount of USDC.
    /// @return IsSuccess
    function sendToUser(
        address _to,
        uint256 _amount
    ) external nonReentrant returns (bool) {
        require(msg.sender == helperAddr, "Invalid caller address.");
        require(_amount > 0, "Amount must be greater than zero");
        usdc.transfer(_to, _amount);
        emit TrasferDetails(address(this), _to, _amount);
        return true;
    }

    function setHelper(address _helperAddr) public onlyAdmin {
        require(_helperAddr != helperAddr && _helperAddr != address(0), "Wrong address");
        helperAddr = _helperAddr;
        emit SetHelper(_helperAddr);
    }

    function setControl(address _control) public onlyAdmin {
        require(_control != address(strategyManager) && _control != address(0), "Wrong address");
        strategyManager = IStrategyManager(_control);
        emit SetControl(_control);
    }
}
