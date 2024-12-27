// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAuthorityControl} from "./interfaces/IAuthorityControl.sol";

contract StrategyManager is Ownable {
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
    StrategyInfo[] private strategyList;
    uint256[] private chainIDs;

    IAuthorityControl private authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(address _accessAddr) Ownable(msg.sender) {
        authorityControl = IAuthorityControl(_accessAddr);
    }

    /*    -------------- Events --------------    */
    event AddStrategy(uint256 chainID, address strategy);
    event ActivateStrategy(uint256 chainID, address strategy);
    event RemoveStrategy(uint256 chainID, address strategy);

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
}
