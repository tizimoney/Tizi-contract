// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";

/**
 * @title Tizi StrategyManager
 * @author tizi.money
 * @notice
 *  SubStrategyManager is deployed on other chains to manage strategies. After
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
        bool canActivate;
        uint256 time;
    }

    mapping(uint256 => mapping(address => Strategy)) public strategies;
    mapping(uint256 => address[]) public activeStrategyAddresses;
    uint256 public cooldownTime = 3 days;
    LiquidityInfo public liquidityInfo;

    StrategyInfo[] private _strategyList;
    uint256[] private _chainIDs;
    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _endpoint,
        address _owner,
        address _accessAddr
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        _authorityControl = IAuthorityControl(_accessAddr);
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
    function toEthSignedMessageHash(
        bytes32 hash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
            );
    }

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

    /*    ---------- Write Functions ----------    */
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

        require(block.timestamp - liquidityInfo.time <= 7200, "Liquidity information over 120 minutes!");
        require(liquidityInfo.canActivate, "No liquidity to active strategy!");

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

    function setCooldownTime(uint256 newCooldownTime) public onlyAdmin {
        require(newCooldownTime != 0 && newCooldownTime != cooldownTime, "Wrong cooldown time!");
        cooldownTime = newCooldownTime;
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyAdmin {
        _setPeer(eid, peer);
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
            _authorityControl.hasRole(
                _authorityControl.DEFAULT_ADMIN_ROLE(),
                signer
            ),
            "Not authorized"
        );
        (bool canActivate, uint256 time) = abi.decode(message, (bool, uint256));
        liquidityInfo.canActivate = canActivate;
        liquidityInfo.time = time;
        emit SignedMessageVerified(signer, hashMessage);
    }
}
