// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAuthorityControl} from "./interfaces/IAuthorityControl.sol";

/**
 * @title Tizi StrategyManager
 * @author tizi.money
 * @notice
 *  StrategyManager is deployed on all chains to manage strategies. After
 *  a strategy is added, its status needs to be set to active before deposits
 *  are allowed. There can be multiple active strategies on a chain, and
 *  the addition, activation and deletion of strategies are controlled
 *  by the Admin.
 */
contract SubStrategyManager is OApp {
    using ECDSA for bytes32;
    struct Strategy {
        bool exists;
        bool active;
        uint256 addedTime;
    }

    struct StrategyInfo {
        uint256 chainID;
        address strategyAddress;
    }

    struct LiquidityInfo {
        bool canActive;
        uint256 time;
    }

    mapping(uint256 => mapping(address => Strategy)) public strategies;
    mapping(uint256 => address[]) public activeStrategyAddresses;
    StrategyInfo[] private strategyList;
    uint256[] private chainIDs;
    uint256 cooldownTime = 3 days;
    LiquidityInfo public liquidityInfo;

    IAuthorityControl private authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _endpoint,
        address _owner,
        address _accessAddr
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        authorityControl = IAuthorityControl(_accessAddr);
    }

    /*    -------------- Events --------------    */
    event AddStrategy(uint256 chainID, address strategy);
    event ActivateStrategy(uint256 chainID, address strategy);
    event RemoveStrategy(uint256 chainID, address strategy);
    event SignedMessageVerified(
        address indexed signer,
        bytes32 indexed messageHash
    );

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
    function toEthSignedMessageHash(
        bytes32 hash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
            );
    }

    function getActiveAddrByChainId(
        uint256 _chainId
    ) public view returns (address[] memory) {
        return activeStrategyAddresses[_chainId];
    }

    function _isContract(address _account) internal view returns (bool) {
        return _account.code.length > 0;
    }

    function getAllActiveStrategies()
        external
        view
        returns (StrategyInfo[] memory)
    {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (
                strategies[strategyList[i].chainID][
                    strategyList[i].strategyAddress
                ].active
            ) {
                activeCount++;
            }
        }

        StrategyInfo[] memory activeStrategies = new StrategyInfo[](
            activeCount
        );
        uint256 index = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (
                strategies[strategyList[i].chainID][
                    strategyList[i].strategyAddress
                ].active
            ) {
                activeStrategies[index] = strategyList[i];
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
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (
                !strategies[strategyList[i].chainID][
                    strategyList[i].strategyAddress
                ].active
            ) {
                inactiveCount++;
            }
        }

        StrategyInfo[] memory inactiveStrategies = new StrategyInfo[](
            inactiveCount
        );
        uint256 index = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (
                !strategies[strategyList[i].chainID][
                    strategyList[i].strategyAddress
                ].active
            ) {
                inactiveStrategies[index] = strategyList[i];
                index++;
            }
        }
        return inactiveStrategies;
    }

    function isStrategyActive(
        uint256 _chainID,
        address _strategyAddress
    ) external view returns (bool) {
        require(
            strategies[_chainID][_strategyAddress].exists,
            "Strategy does not exist"
        );
        return strategies[_chainID][_strategyAddress].active;
    }

    function getAllChainIDs() external view returns (uint256[] memory) {
        return chainIDs;
    }

    function countChainIDs() external view returns (uint256) {
        return chainIDs.length;
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _b) public pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    /*    ---------- Write Functions ----------    */

    /// @notice Used to add a new strategy.
    /// @param _chainID The chain id of given chain.
    /// @param _strategyAddress The address of new strategy.
    function addStrategy(
        uint256 _chainID,
        address _strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(_strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            !strategies[_chainID][_strategyAddress].exists,
            "Strategy exists"
        );
        strategies[_chainID][_strategyAddress] = Strategy({
            exists: true,
            active: false,
            addedTime: block.timestamp
        });
        strategyList.push(
            StrategyInfo({chainID: _chainID, strategyAddress: _strategyAddress})
        );
        bool isNewChainID = true;
        for (uint256 i = 0; i < chainIDs.length; i++) {
            if (chainIDs[i] == _chainID) {
                isNewChainID = false;
                break;
            }
        }
        if (isNewChainID) {
            chainIDs.push(_chainID);
        }

        emit AddStrategy(_chainID, _strategyAddress);
    }

    /// @notice Used to activate a new strategy.
    /// @param _chainID The chain id of given chain.
    /// @param _strategyAddress The address of new strategy.
    function activateStrategy(
        uint256 _chainID,
        address _strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(_strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            strategies[_chainID][_strategyAddress].exists,
            "Strategy does not exist"
        );
        require(
            block.timestamp - strategies[_chainID][_strategyAddress].addedTime >= cooldownTime,
            "Adding time is less than the cooldown time."
        );

        require(block.timestamp - liquidityInfo.time <= 7200, "Liquidity information over 120 minutes!");
        require(liquidityInfo.canActive, "No liquidity to active strategy!");

        strategies[_chainID][_strategyAddress].active = true;
        activeStrategyAddresses[_chainID].push(_strategyAddress);
        emit ActivateStrategy(_chainID, _strategyAddress);
    }

    /// @notice Used to remove a exist strategy.
    /// @param _chainID The chain id of given chain.
    /// @param _strategyAddress The address of strategy.
    function removeStrategy(
        uint256 _chainID,
        address _strategyAddress
    ) external onlyAdmin {
        require(
            _isContract(_strategyAddress) == true,
            "The address must be a contract"
        );
        require(
            strategies[_chainID][_strategyAddress].exists,
            "Strategy does not exist"
        );
        delete strategies[_chainID][_strategyAddress];
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (
                strategyList[i].chainID == _chainID &&
                strategyList[i].strategyAddress == _strategyAddress
            ) {
                strategyList[i] = strategyList[strategyList.length - 1];
                strategyList.pop();
                break;
            }
        }

        address[] storage activeAddresses = activeStrategyAddresses[_chainID];
        for (uint256 i = 0; i < activeAddresses.length; i++) {
            if (activeAddresses[i] == _strategyAddress) {
                activeAddresses[i] = activeAddresses[
                    activeAddresses.length - 1
                ];
                activeAddresses.pop();
                break;
            }
        }
        emit RemoveStrategy(_chainID, _strategyAddress);
    }

    function setCooldownTime(uint256 _cooldownTime) public onlyAdmin {
        require(_cooldownTime != 0 && _cooldownTime != cooldownTime, "Wrong cooldown time!");
        cooldownTime = _cooldownTime;
    }

    function setPeer(uint32 _eid, bytes32 _peer) public override onlyAdmin {
        _setPeer(_eid, _peer);
    }

    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata payload,
        address,  // Executor address as specified by the OApp.
        bytes calldata  // Any extra data or options to trigger on receipt.
    ) internal override {
        (bytes memory signedMessage, bytes memory message) = abi.decode(
            payload,
            (bytes, bytes)
        );
        bytes32 hashMessage = keccak256(message);
        bytes32 ethMessage = toEthSignedMessageHash(hashMessage);
        address signer = ethMessage.recover(signedMessage);
        require(
            authorityControl.hasRole(
                authorityControl.DEFAULT_ADMIN_ROLE(),
                signer
            ),
            "Not authorized"
        );
        (bool canActive, uint256 time) = abi.decode(message, (bool, uint256));
        liquidityInfo.canActive = canActive;
        liquidityInfo.time = time;
        emit SignedMessageVerified(signer, hashMessage);
    }
}
