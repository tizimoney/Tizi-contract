// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

interface ITransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool);
}

interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
} 

/**
 * @title Tizi SubVault
 * @author tizi.money
 * @notice
 *  SubVault use CCTPV2, and is the first place where USDC is stored
 *  on other chains. SubVault receives USDC transferred from the Base chain
 *  via CCTPV2, and then the Manager decides which strategies to store
 *  USDC in. You cannot withdraw money in SubVault, and USDC will eventually
 *  be transferred to the Base chain via CCTPV2.
 * 
 *  Only one MainVault supports transfers, and the management and changes
 *  of MainVault are determined by the Admin.
 * 
 *  SubVault determines the deposits, withdrawals, and harvests of the
 *  current chain's strategy, is managed by the Manager, and can view the
 *  asset information in the strategy.
 */
contract SubVault {
    address public usdcAddr;
    address public mainVault;

    ITokenMessengerV2 public tokenMessenger;
    IAuthorityControl private authorityControl;
    ITransmitter private transmitter;
    IStrategyManager private strategyManager;
    IRouterClient public ccipRouter;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _usdcAddr,
        address _transmitter,
        address _tokenMessenger,
        address _ccipRouter
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
        usdcAddr = _usdcAddr;
        transmitter = ITransmitter(_transmitter);
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
        ccipRouter = IRouterClient(_ccipRouter);
    }

    /*    -------------- Events --------------    */
    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event TokensTransferredCCIP( 
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        address token,
        uint256 tokenAmount,
        address feeToken,
        uint256 fees
    );
    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event BridgeInInfo(bytes32 messageHash);
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

    function getCCIPFee(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(_receiver, _token, _amount, address(0));

        // Get the fee required to send the message
        uint256 fee = ccipRouter.getFee(_destinationChainSelector, evm2AnyMessage);
        return fee;
    }

    /*    ---------- Write Functions ----------    */

    /// @notice Call the receiveMessage function of the CCTPV2 transmitter to receive cross-chain USDC.
    /// @param _message The information sent by mainVault.
    /// @param _attestation Attestation from CCTPV2.
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

    /// @notice Call CCTPV2 tokenMessenger function to only allow sending to registered vault addresses.
    /// @param _amount The amount of USDC.
    /// @param _destDomain The domain of destination chain.
    /// @param _receiver The address of mainVault.
    /// @param _maxFee Choose fast cross-chain or normal cross-chain.
    /// @param _minFinalityThreshold Choose fast cross-chain or normal cross-chain.
    function bridgeOut(
        uint256 _amount,
        uint32 _destDomain,
        address _receiver,
        uint256 _maxFee,
        uint32 _minFinalityThreshold
    ) public onlyManager {
        require(_amount > 0, "Amount must be greater than zero");
        require(_receiver == mainVault, "Receiver is not vault");
        IERC20(usdcAddr).approve(address(tokenMessenger), _amount);
        tokenMessenger.depositForBurn(
           _amount,
           _destDomain,
           addressToBytes32(_receiver),
           usdcAddr,
           bytes32(0),
           _maxFee,
           _minFinalityThreshold
        );
        emit BridgeToInfo(_destDomain, _receiver, _amount);
    }

    /// @notice Transfer tokens to receiver on the destination chain.
    /// @notice Pay in native gas such as ETH on Ethereum or POL on Polygon.
    /// @notice the token must be in the list of supported tokens.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or POL on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _token token address.
    /// @param _amount token amount.
    /// @return messageId The ID of the message that was sent.
    function transferTokensCCIP(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    ) external payable onlyManager returns (bytes32 messageId) {
        require(_amount > 0, "Amount must be greater than zero");
        require(_receiver == mainVault, "Receiver is not vault");
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(_receiver, _token, _amount, address(0));

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(_token).approve(address(ccipRouter), _amount);

        // Send the message through the router and store the returned message ID
        messageId = ccipRouter.ccipSend{value: msg.value}(_destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit TokensTransferredCCIP(messageId, _destinationChainSelector, _receiver, _token, _amount, address(0), msg.value);

        // Return the message ID
        return messageId;
    }

    function setMainVault(address _vault) external onlyAdmin {
        require(_vault != address(0) && _vault != mainVault, "Wrong vault address");
        mainVault = _vault;
    }

    function setTokenMessenger(address _tokenMessenger) external onlyAdmin {
        require(_tokenMessenger != address(0) && _tokenMessenger != address(tokenMessenger), "Wrong messenger address");
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
    }

    function setTransmitter(address _transmitter) external onlyAdmin {
        require(_transmitter != address(0) && _transmitter != address(transmitter), "Wrong address");
        transmitter = ITransmitter(_transmitter);
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
            _amount = IERC20(usdcAddr).balanceOf(_farm);
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
        require(IERC20(usdcAddr).transfer(_farm, _amount) == true, "transfer failure");
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
            IERC20(usdcAddr).balanceOf(_farm) >= _amount,
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

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for tokens transfer.
    /// @param _receiver The address of the receiver.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP
    /// message.
    function _buildCCIPMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return Client.EVM2AnyMessage({
        receiver: abi.encode(_receiver), // ABI-encoded receiver address
        data: "", // No data
        tokenAmounts: tokenAmounts, // The amount and type of token being transferred
        extraArgs: Client._argsToBytes(
            // Additional arguments, setting gas limit and allowing out-of-order execution.
            // Best Practice: For simplicity, the values are hardcoded. It is advisable to use a more dynamic approach
            // where you set the extra arguments off-chain. This allows adaptation depending on the lanes, messages,
            // and ensures compatibility with future CCIP upgrades. Read more about it here:
            // https://docs.chain.link/ccip/concepts/best-practices/evm#using-extraargs
            Client.GenericExtraArgsV2({
            gasLimit: 0, // Gas limit for the callback on the destination chain
            allowOutOfOrderExecution: true // Allows the message to be executed out of order relative to other messages
            // from
            // the same sender
            })
        ),
        // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
        feeToken: _feeTokenAddress
        });
    }
}
