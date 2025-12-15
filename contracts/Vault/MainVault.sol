// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { IFarm } from "../interfaces/IFarm.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IStrategyManager } from "../interfaces/IStrategyManager.sol";
import { ISharedStructs } from "../interfaces/ISharedStructs.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

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

interface IMessageTransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool);
}

interface IDepositHelper {
    function calculateLiquidity() external view returns (uint256 liquidity, bool canActive);
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
 *  addresses stored in allowedVaults allow transfers.
 * 
 *  MainVault determines the deposits, withdrawals, and harvests of the
 *  current chain's strategy, which is managed by Manager, and the asset
 *  information in the strategy can be viewed.
 */
contract MainVault is ISharedStructs, ReentrancyGuard {
    address public depositHelper;
    ITokenMessengerV2 public tokenMessenger;
    IStrategyManager public strategyManager;
    address public usdc;
    IMessageTransmitter public messageTransmitter;
    IRouterClient public ccipRouter;

    /// (vault address => is allowed to transfer though CCTP)
    mapping(address => bool) public allowedVaults;

    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _messageTransmitter,
        address _tokenMessenger,
        address _usdc,
        address _ccipRouter
    ) {
        _authorityControl = IAuthorityControl(_accessAddr);
        usdc = _usdc;
        messageTransmitter = IMessageTransmitter(_messageTransmitter);
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
        ccipRouter = IRouterClient(_ccipRouter);
    }

    /*    -------------- Events --------------    */
    event TransferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event BridgeOutCCIP( 
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
    event SetStrategyManager(address strategyManager);
    event SetDepositHelper(address depositHelper);

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
    /// @notice Check information about tokens in a strategy, only the current chain is allowed.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    /// @return Tokens info.
    function check(uint256 chainId, address farm) public view returns (IFarm.EarlierProfits[] memory) {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm.EarlierProfits[] memory checkArray = IFarm(farm).check();
        return checkArray;
    }

    function addressToBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function getCCIPFee(
        uint64 destinationChainSelector,
        address receiver,
        address token,
        uint256 amount
    ) public view returns (uint256) {
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(receiver, token, amount, address(0));

        // Get the fee required to send the message
        uint256 fee = ccipRouter.getFee(destinationChainSelector, evm2AnyMessage);
        return fee;
    }

    /*    ---------- Write Functions ----------    */
    /// @notice Call the receiveMessage function of the CCTPV2 messageTransmitter to receive cross-chain USDC.
    /// @param message The information sent by mainVault.
    /// @param attestation Attestation from CCTPV2.
    function bridgeIn(
        bytes calldata message,
        bytes calldata attestation
    ) public onlyManager {
        require(
            messageTransmitter.receiveMessage(message, attestation) == true,
            "collection failure"
        );
        emit BridgeInInfo(keccak256(message));
    }

    /// @notice Call CCTPV2 tokenMessenger function to only allow sending to registered vault addresses.
    /// @param amount The amount of USDC.
    /// @param destDomain The domain of destination chain.
    /// @param receiver The address of subVault.
    /// @param maxFee Choose fast cross-chain or normal cross-chain.
    /// @param minFinalityThreshold Choose fast cross-chain or normal cross-chain.
    function bridgeOut(
        uint256 amount,
        uint32 destDomain,
        address receiver,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) public onlyManager {
        require(amount > 0, "Amount must be greater than zero");
        require(allowedVaults[receiver] == true, "Receiver is not vault");
        (uint256 liquidity, ) = IDepositHelper(depositHelper).calculateLiquidity();
        require(amount <= liquidity, "Amount is larger than liquidity");
        IERC20(usdc).approve(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
           amount,
           destDomain,
           addressToBytes32(receiver),
           usdc,
           bytes32(0),
           maxFee,
           minFinalityThreshold
        );
        emit BridgeToInfo(destDomain, receiver, amount);
    }

    /// @notice Transfer tokens to receiver on the destination chain.
    /// @notice Pay in native gas such as ETH on Ethereum or POL on Polygon.
    /// @notice the token must be in the list of supported tokens.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or POL on Polygon.
    /// @param destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param receiver The address of the recipient on the destination blockchain.
    /// @param token token address.
    /// @param amount token amount.
    /// @return The ID of the message that was sent.
    function bridgeOutCCIP(
        uint64 destinationChainSelector,
        address receiver,
        address token,
        uint256 amount
    ) external payable onlyManager returns (bytes32) {
        require(amount > 0, "Amount must be greater than zero");
        require(allowedVaults[receiver] == true, "Receiver is not vault");
        (uint256 liquidity, ) = IDepositHelper(depositHelper).calculateLiquidity();
        require(amount <= liquidity, "Amount is larger than liquidity");
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(receiver, token, amount, address(0));

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(token).approve(address(ccipRouter), amount);

        // Send the message through the router and store the returned message ID
        bytes32 messageId = ccipRouter.ccipSend{value: msg.value}(destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit BridgeOutCCIP(messageId, destinationChainSelector, receiver, token, amount, address(0), msg.value);

        // Return the message ID
        return messageId;
    }

    function addAllowedVaults(address[] memory vaults) external onlyAdmin {
        (, bool isAllow) = IDepositHelper(depositHelper).calculateLiquidity();
        require(isAllow, "No liquidity to add new SubVault!");
        require(vaults.length > 0, "Please input at least one address");

        for(uint i = 0; i < vaults.length; ++i) {
            require(vaults[i] != address(0), "Wrong vault address");
            allowedVaults[vaults[i]] = true;
        }
    }

    function setMessageTransmitter(address newMessageTransmitter) external onlyAdmin {
        require(newMessageTransmitter != address(0) && newMessageTransmitter != address(messageTransmitter), "Wrong address");
        messageTransmitter = IMessageTransmitter(newMessageTransmitter);
    }

    function setCCIPRouter(address newCcipRouter) external onlyAdmin {
        require(newCcipRouter != address(0) && newCcipRouter != address(ccipRouter), "Wrong address");
        ccipRouter = IRouterClient(newCcipRouter);
    }

    function setTokenMessenger(address newTokenMessenger) external onlyAdmin {
        require(newTokenMessenger != address(0) && newTokenMessenger != address(tokenMessenger), "Wrong messenger address");
        tokenMessenger = ITokenMessengerV2(newTokenMessenger);
    }

    /// @notice Transfer USDC from strategy to vault.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    /// @param amount The amount of USDC.
    function exitFarm(uint256 chainId, address farm, uint256 amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        if (amount == 0) {
            amount = IERC20(usdc).balanceOf(farm);
            require(amount > 0, "Amount must be greater than zero");
        }
        IFarm(farm).toVault(amount);
        emit TransferDetails(farm, address(this), amount);
    }

    /// @notice Transfer USDC from vault to strategy.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    /// @param amount The amount of USDC.
    function enterFarm(uint256 chainId, address farm, uint256 amount) public onlyManager returns (bool) {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        require(amount > 0, "Amount must be greater than zero");
        require(IERC20(usdc).transfer(farm, amount) == true, "transfer failure");
        emit TransferDetails(address(this), farm, amount);
        return true;
    }

    /// @notice Call deposit function in strategy, start to farm.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    /// @param amount The amount of USDC.
    function deposit(uint256 chainId, address farm, uint256 amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        require(
            IERC20(usdc).balanceOf(farm) >= amount,
            "farm balance insufficient"
        );
        IFarm(farm).deposit(amount);
    }

    /// @notice Call withdraw function in strategy, withdraw a certain amount of USDC to strategy contract.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    /// @param amount The amount of USDC.
    function withdraw(uint256 chainId, address farm, uint256 amount) public onlyManager {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm(farm).withdraw(amount);
    }

    /// @notice Call harvest function in strategy, withdraw additional tokens to strategy contract.
    /// @param chainId The chain id where the strategy is located.
    /// @param farm The address of strategy.
    function harvest(uint256 chainId, address farm) public onlyManager {
        require(
            strategyManager.isStrategyActive(chainId, farm) == true,
            "Farm inactive or non-existent"
        );
        IFarm(farm).harvest();
    }

    /// @notice Only used in mainVault, sent to the user when someone withdraws money.
    /// @param to Receiver address.
    /// @param amount The amount of USDC.
    /// @return IsSuccess
    function sendToUser(
        address to,
        uint256 amount
    ) external nonReentrant returns (bool) {
        require(msg.sender == depositHelper, "Invalid caller address.");
        require(amount > 0, "Amount must be greater than zero");
        IERC20(usdc).transfer(to, amount);
        emit TransferDetails(address(this), to, amount);
        return true;
    }

    function setDepositHelper(address newDepositHelper) public onlyAdmin {
        require(newDepositHelper != depositHelper && newDepositHelper != address(0), "Wrong address");
        depositHelper = newDepositHelper;
        emit SetDepositHelper(newDepositHelper);
    }

    function setStrategyManager(address newStrategyManager) public onlyAdmin {
        require(newStrategyManager != address(strategyManager) && newStrategyManager != address(0), "Wrong address");
        strategyManager = IStrategyManager(newStrategyManager);
        emit SetStrategyManager(newStrategyManager);
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for tokens transfer.
    /// @param receiver The address of the receiver.
    /// @param token The token to be transferred.
    /// @param amount The amount of the token to be transferred.
    /// @param feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP
    /// message.
    function _buildCCIPMessage(
        address receiver,
        address token,
        uint256 amount,
        address feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return Client.EVM2AnyMessage({
        receiver: abi.encode(receiver), // ABI-encoded receiver address
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
        feeToken: feeTokenAddress
        });
    }
}
