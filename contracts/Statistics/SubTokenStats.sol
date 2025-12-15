// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IFarm } from "../interfaces/IFarm.sol";
import { IStrategyManager } from "../interfaces/IStrategyManager.sol";

/**
 * @title Tizi SubTokenStats
 * @author tizi.money
 * @notice
 *  SubTokenStats is deployed on chains other than Base to collect
 *  statistics on all assets on this chain, including USDC and other tokens.
 *  SubTokenStats traverses all strategies and vaults on the Base chain
 *  through strategiesStats to obtain the number and price of tokens in
 *  the strategy. It is packaged in the SubTokenAxelar or SubTokenLayerZero
 *  contract and sent to MainTokenStats.
 */
contract SubTokenStats {
    IERC20 public immutable USDC;
    uint256 public immutable CHAINID;
    address public subAxelar;
    address public subLayerZero;
    address public vault;
    address public usdcAddr;

    IAuthorityControl private _authorityControl;
    IStrategyManager private _strategyManager;

    struct Strategy {
        uint256 chainID;
        address contractAddress;
        IFarm.TokenInfo[] tokenInfo;
    }

    /// (chainid => (strategyAddress => tokenInfo))
    mapping(uint256 => mapping(address => mapping(address => IFarm.TokenInfo)))
        public chainStrategies;
    /// (chainid => (strategyAddress => tokenAddresses))
    mapping(uint256 => mapping(address => address[])) public tokenList;
    /// (chainid => strategyAddresses)
    mapping(uint256 => address[]) public chainStrategyKeys;
    uint256[] public chainIDs;

    /*    ------------ Constructor ------------    */
    constructor(
        address _USDC,
        address _access,
        address _control,
        uint256 _chainID
    ) {
        USDC = IERC20(_USDC);
        _authorityControl = IAuthorityControl(_access);
        _strategyManager = IStrategyManager(_control);
        usdcAddr = _USDC;
        CHAINID = _chainID;
    }

    /*    -------------- Events --------------    */
    event SetAxelar(address axelar);
    event SetLayerZero(address layerzero);
    event SetVault(address vault);

    /*    ------------- Modifiers ------------    */
    modifier onlyAxelarorLZ() {
        require(msg.sender == subAxelar || msg.sender == subLayerZero, "Not authorized");
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
    function getChainID() public view returns (uint256[] memory) {
        return chainIDs;
    }

    /// @notice Used to get token info of given strategy.
    /// @param chainID The chain id of given chain.
    /// @param contractAddress The address of given strategy.
    /// @return Token info.
    function getStrategyTokenInfo(
        uint256 chainID,
        address contractAddress
    ) public view returns (IFarm.TokenInfo[] memory) {
        address[] memory tokenAddresses = tokenList[chainID][contractAddress];
        IFarm.TokenInfo[] memory infos = new IFarm.TokenInfo[](
            tokenAddresses.length
        );
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            infos[i] = chainStrategies[chainID][contractAddress][
                tokenAddresses[i]
            ];
        }
        return infos;
    }

    /// @notice Used to get strategy addresses of given chain.
    /// @param chainID The chain id of given chain.
    /// @return Strategy info.
    function getStrategiesForChain(
        uint256 chainID
    ) public view returns (Strategy[] memory) {
        address[] memory keys = chainStrategyKeys[chainID];
        uint256 count = keys.length;
        Strategy[] memory strategies = new Strategy[](count);
        for (uint256 i = 0; i < count; i++) {
            address contractAddress = keys[i];
            strategies[i] = Strategy({
                chainID: chainID,
                contractAddress: contractAddress,
                tokenInfo: getStrategyTokenInfo(chainID, contractAddress)
            });
        }
        return strategies;
    }

    /// @notice Used to get add strategy addresses.
    /// @return Strategy info.
    function getAllStrategies() public view returns (Strategy[] memory) {
        uint256 totalStrategies = 0;
        for (uint256 i = 0; i < chainIDs.length; i++) {
            totalStrategies += chainStrategyKeys[chainIDs[i]].length;
        }

        Strategy[] memory allStrategies = new Strategy[](totalStrategies);
        uint256 index = 0;

        for (uint256 i = 0; i < chainIDs.length; i++) {
            uint256 chainID = chainIDs[i];
            address[] memory keys = chainStrategyKeys[chainID];
            for (uint256 j = 0; j < keys.length; j++) {
                address contractAddress = keys[j];
                allStrategies[index] = Strategy({
                    chainID: chainID,
                    contractAddress: contractAddress,
                    tokenInfo: getStrategyTokenInfo(chainID, contractAddress)
                });
                index++;
            }
        }

        return allStrategies;
    }

    /// @notice Used to get token info of given strategy.
    /// @param chainID The chain id of given chain.
    /// @param strategyAddress The address of strategy.
    /// @param tokenAddress The address of token.
    /// @return Token info.
    function getTokenInfoByAddresses(
        uint256 chainID,
        address strategyAddress,
        address tokenAddress
    ) public view returns (IFarm.TokenInfo memory) {
        return chainStrategies[chainID][strategyAddress][tokenAddress];
    }

    function getTotalTokenValue() public view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < chainIDs.length; i++) {
            uint256 chainID = chainIDs[i];
            address[] memory strategyAddresses = chainStrategyKeys[chainID];
            for (uint256 j = 0; j < strategyAddresses.length; j++) {
                address strategyAddress = strategyAddresses[j];
                address[] memory tokenAddresses = tokenList[chainID][
                    strategyAddress
                ];
                for (uint256 k = 0; k < tokenAddresses.length; k++) {
                    address tokenAddress = tokenAddresses[k];
                    totalValue += chainStrategies[chainID][strategyAddress][
                        tokenAddress
                    ].tokenValue;
                }
            }
        }
        return totalValue;
    }

    function isContractAddressAdded(
        uint256 chainID,
        address contractAddress
    ) internal view returns (bool) {
        address[] memory existingAddresses = chainStrategyKeys[chainID];
        for (uint256 i = 0; i < existingAddresses.length; i++) {
            if (existingAddresses[i] == contractAddress) {
                return true;
            }
        }
        return false;
    }

    function chainExists(uint256 chainID) internal view returns (bool) {
        for (uint256 i = 0; i < chainIDs.length; i++) {
            if (chainIDs[i] == chainID) {
                return true;
            }
        }
        return false;
    }

    /*    ---------- Write Functions ----------    */

    /// @notice Get the token information of each strategy on the current chain.
    function strategiesStats() public onlyAxelarorLZ {
        _clearDataByChainId();
        _addVaultInfo();
        address[] memory activeAddresses = _strategyManager
            .getActiveAddrByChainId(CHAINID);
        for (uint256 i = 0; i < activeAddresses.length; i++) {
            address contractAddress = activeAddresses[i];
            IFarm.TokenInfo[] memory info = IFarm(contractAddress)
                .getTokenInfo();
            chainStrategyKeys[CHAINID].push(contractAddress);
            address[] memory tokenLists = new address[](info.length);
            for (uint256 k = 0; k < info.length; k++) {
                tokenLists[k] = info[k].tokenAddress;
            }
            tokenList[CHAINID][contractAddress] = tokenLists;
            for (uint256 j = 0; j < tokenLists.length; j++) {
                chainStrategies[CHAINID][contractAddress][tokenLists[j]] = info[
                    j
                ];
            }
        }
    }

    /// @notice Add the USDC information in the vault.
    function _addVaultInfo() internal {
        chainStrategyKeys[CHAINID].push(vault);
        address[] memory tokenLists = new address[](1);
        tokenLists[0] = usdcAddr;
        tokenList[CHAINID][vault] = tokenLists;
        IFarm.TokenInfo memory tokenInfo = IFarm.TokenInfo({
            tokenAddress: usdcAddr,
            timestamp: 0,
            negativeGrowth: false,
            tokenAmount: (USDC.balanceOf(vault) * (10 ** 18)) /
                (10 ** USDC.decimals()),
            tokenValue: 10 ** 18
        });
        chainStrategies[CHAINID][vault][tokenLists[0]] = tokenInfo;
        if (!chainExists(CHAINID)) {
            chainIDs.push(CHAINID);
        }
    }

    function setAxelar(address newAxelar) public onlyAdmin {
        require(newAxelar != address(0) && newAxelar != subAxelar, "Wrong address");
        subAxelar = newAxelar;
        emit SetAxelar(newAxelar);
    }

    function setLayerZero(address newLayerzero) public onlyAdmin {
        require(newLayerzero != address(0) && newLayerzero != subLayerZero, "Wrong address");
        subLayerZero = newLayerzero;
        emit SetLayerZero(newLayerzero);
    }

    function setVault(address newVault) public onlyAdmin {
        require(newVault != address(0) && newVault != vault, "Wrong address");
        vault = newVault;
        emit SetVault(newVault);
    }

    /// @notice Clear statistics, called before each statistics. 
    function _clearDataByChainId() private {
        address[] storage addresses = chainStrategyKeys[CHAINID];

        for (uint256 j = 0; j < addresses.length; j++) {
            address contractAddress = addresses[j];
            address[] storage tokens = tokenList[CHAINID][contractAddress];

            for (uint256 k = 0; k < tokens.length; k++) {
                delete chainStrategies[CHAINID][contractAddress][tokens[k]];
            }
            delete tokenList[CHAINID][contractAddress];
        }
        delete chainStrategyKeys[CHAINID];

        for (uint256 i = 0; i < chainIDs.length; i++) {
            if (chainIDs[i] == CHAINID) {
                chainIDs[i] = chainIDs[chainIDs.length - 1];
                chainIDs.pop();
                break;
            }
        }
    }
}
