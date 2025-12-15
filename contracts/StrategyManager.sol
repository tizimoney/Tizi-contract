// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

interface IDepositHelper {
    function calculateLiquidity() external view returns (uint256 liquidity, bool canActive);
}

/**
 * @title Tizi StrategyManager
 * @author tizi.money
 * @notice
 *  StrategyManager is deployed on Base chain to manage strategies. After
 *  a strategy is added, its status needs to be set to active before deposits
 *  are allowed. There can be multiple active strategies on a chain, and
 *  the addition, activation and deletion of strategies are controlled
 *  by the Admin.
 */
contract StrategyManager is OApp {
    using OptionsBuilder for bytes;

    struct Strategy {
        bool exists;
        bool active;
        uint256 addedTime;
    }

    struct StrategyInfo {
        uint256 chainID;
        address strategyAddress;
    }

    mapping(uint256 => mapping(address => Strategy)) public strategies;
    mapping(uint256 => address[]) public activeStrategyAddresses;
    address public depositHelper;
    uint256 public cooldownTime = 3 days;
    bytes public gasOptions;
    bytes public liquidityInfo;

    StrategyInfo[] private _strategyList;
    uint256[] private _chainIDs;
    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _endpoint,
        address _owner,
        address _accessAddr,
        address _depositHelper
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        _authorityControl = IAuthorityControl(_accessAddr);
        depositHelper = _depositHelper;
    }

    /*    -------------- Events --------------    */
    event AddStrategy(uint256 chainID, address strategy);
    event ActivateStrategy(uint256 chainID, address strategy);
    event RemoveStrategy(uint256 chainID, address strategy);
    event MessageSent(bytes payload , uint32 dstEid);

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
    function getActiveAddrByChainId(
        uint256 chainID
    ) public view returns (address[] memory) {
        return activeStrategyAddresses[chainID];
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    function getAllActiveStrategies()
        external
        view
        returns (StrategyInfo[] memory)
    {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _strategyList.length; i++) {
            if (
                strategies[_strategyList[i].chainID][
                    _strategyList[i].strategyAddress
                ].active
            ) {
                activeCount++;
            }
        }

        StrategyInfo[] memory activeStrategies = new StrategyInfo[](
            activeCount
        );
        uint256 index = 0;
        for (uint256 i = 0; i < _strategyList.length; i++) {
            if (
                strategies[_strategyList[i].chainID][
                    _strategyList[i].strategyAddress
                ].active
            ) {
                activeStrategies[index] = _strategyList[i];
                index++;
            }
        }
        return activeStrategies;
    }

    function getAllInactiveStrategies()
        external
        view
        returns (StrategyInfo[] memory)
    {
        uint256 inactiveCount = 0;
        for (uint256 i = 0; i < _strategyList.length; i++) {
            if (
                !strategies[_strategyList[i].chainID][
                    _strategyList[i].strategyAddress
                ].active
            ) {
                inactiveCount++;
            }
        }

        StrategyInfo[] memory inactiveStrategies = new StrategyInfo[](
            inactiveCount
        );
        uint256 index = 0;
        for (uint256 i = 0; i < _strategyList.length; i++) {
            if (
                !strategies[_strategyList[i].chainID][
                    _strategyList[i].strategyAddress
                ].active
            ) {
                inactiveStrategies[index] = _strategyList[i];
                index++;
            }
        }
        return inactiveStrategies;
    }

    function isStrategyActive(
        uint256 chainID,
        address strategyAddress
    ) external view returns (bool) {
        require(
            strategies[chainID][strategyAddress].exists,
            "Strategy does not exist"
        );
        return strategies[chainID][strategyAddress].active;
    }

    function getAllChainIDs() external view returns (uint256[] memory) {
        return _chainIDs;
    }

    function countChainIDs() external view returns (uint256) {
        return _chainIDs.length;
    }

    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function bytes32ToAddress(bytes32 bytes32Address) public pure returns (address) {
        return address(uint160(uint256(bytes32Address)));
    }

    function calculateLiquidity() public view returns (uint256 liquidity, bool canActive) {
        return IDepositHelper(depositHelper).calculateLiquidity();
    }

    function quote(
        uint32 dstEid,
        string memory signedMessage,
        bool payInLzToken
    ) public view returns (MessagingFee memory) {
        bytes memory messageBytes = abi.encode(signedMessage, liquidityInfo);
        bytes memory payload = messageBytes;
        MessagingFee memory fee = _quote(dstEid, payload, gasOptions, payInLzToken);
        return fee;
    }

    /*    ---------- Write Functions ----------    */
    function setLiquidityInfo() public onlyAdmin {
        (, bool canActivate) = IDepositHelper(depositHelper).calculateLiquidity();
        bytes memory tokenCode = abi.encode(canActivate, block.timestamp);
        liquidityInfo = tokenCode;
    }

    /// @notice Used to add a new strategy.
    /// @param chainID The chain id of given chain.
    /// @param strategyAddress The address of new strategy.
    function addStrategy(
        uint256 chainID,
        address strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            !strategies[chainID][strategyAddress].exists,
            "Strategy exists"
        );
        strategies[chainID][strategyAddress] = Strategy({
            exists: true,
            active: false,
            addedTime: block.timestamp
        });
        _strategyList.push(
            StrategyInfo({chainID: chainID, strategyAddress: strategyAddress})
        );
        bool isNewChainID = true;
        for (uint256 i = 0; i < _chainIDs.length; i++) {
            if (_chainIDs[i] == chainID) {
                isNewChainID = false;
                break;
            }
        }
        if (isNewChainID) {
            _chainIDs.push(chainID);
        }

        emit AddStrategy(chainID, strategyAddress);
    }

    /// @notice Used to activate a new strategy.
    /// @param chainID The chain id of given chain.
    /// @param strategyAddress The address of new strategy.
    function activateStrategy(
        uint256 chainID,
        address strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            strategies[chainID][strategyAddress].exists,
            "Strategy does not exist"
        );
        require(
            block.timestamp - strategies[chainID][strategyAddress].addedTime >= cooldownTime,
            "Adding time is less than the cooldown time."
        );

        (, bool canActivate) = IDepositHelper(depositHelper).calculateLiquidity();
        require(canActivate, "No liquidity to active strategy!");

        strategies[chainID][strategyAddress].active = true;
        activeStrategyAddresses[chainID].push(strategyAddress);
        emit ActivateStrategy(chainID, strategyAddress);
    }

    /// @notice Used to remove a exist strategy.
    /// @param chainID The chain id of given chain.
    /// @param strategyAddress The address of strategy.
    function removeStrategy(
        uint256 chainID,
        address strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            strategies[chainID][strategyAddress].exists,
            "Strategy does not exist"
        );
        delete strategies[chainID][strategyAddress];
        for (uint256 i = 0; i < _strategyList.length; i++) {
            if (
                _strategyList[i].chainID == chainID &&
                _strategyList[i].strategyAddress == strategyAddress
            ) {
                _strategyList[i] = _strategyList[_strategyList.length - 1];
                _strategyList.pop();
                break;
            }
        }

        address[] storage activeAddresses = activeStrategyAddresses[chainID];
        for (uint256 i = 0; i < activeAddresses.length; i++) {
            if (activeAddresses[i] == strategyAddress) {
                activeAddresses[i] = activeAddresses[
                    activeAddresses.length - 1
                ];
                activeAddresses.pop();
                break;
            }
        }
        emit RemoveStrategy(chainID, strategyAddress);
    }

    function send(
        uint32 dstEid,
        bytes calldata signedMessage
    ) external payable onlyAdmin {
        bytes memory messageBytes = abi.encode(signedMessage, liquidityInfo);
        bytes memory payload = messageBytes;

        _lzSend(
            dstEid,
            payload,
            gasOptions,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit MessageSent(payload, dstEid);
    }

    function setCooldownTime(uint256 newCooldownTime) public onlyAdmin {
        require(newCooldownTime != 0 && newCooldownTime != cooldownTime, "Wrong cooldown time!");
        cooldownTime = newCooldownTime;
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyAdmin {
        _setPeer(eid, peer);
    }

    function setOptions(uint128 gasLimit, uint128 msgValue) public onlyAdmin {
        bytes memory newOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, msgValue);
        gasOptions = newOptions;
    }

    function setDepositHelper(address newHelper) public onlyAdmin {
        require(newHelper != address(0) && newHelper != depositHelper, "Wrong address!");
        depositHelper = newHelper;
    }

    /**
     * @dev Called when data is received from the protocol. It overrides the equivalent function in the parent contract.
     * Protocol messages are defined as packets, comprised of the following parameters.
     * @param origin A struct containing information about where the packet came from.
     * @param guid A global unique identifier for tracking the packet.
     * @param payload Encoded message.
     */
    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address,  // Executor address as specified by the OApp.
        bytes calldata  // Any extra data or options to trigger on receipt.
    ) internal override {
        // Decode the payload to get the message
        // In this case, type is string, but depends on your encoding!
        //data = abi.decode(payload, (string));
    }
}
