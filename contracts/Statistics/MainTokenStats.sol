// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";

/**
 * @title Tizi MainTokenStats
 * @author tizi.money
 * @notice
 *  MainTokenStats counts all assets, including USDC and other tokens.
 *  Before each rebase, MainTokenStats first traverses all strategies and
 *  vaults on the Base chain through strategiesStats to obtain the number
 *  and price of tokens in the strategy. It then parses and stores the
 *  information received from other chains, and calculates the total asset
 *  price on the final chain as the basis for rebase.
 */
contract MainTokenStats {
    IAuthorityControl private authorityControl;
    IStrategyManager private strategyManager;
    IERC20 public immutable USDC;

    address public mainAxelar;
    address public mainLayerZero;
    address public vault;
    address public usdcAddr;
    uint256 public immutable CHAINID;

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
    /// (chainid => (strategyAddress => totalValue))
    mapping(uint256 => mapping(address => uint256)) public strategyTotalValues;
    /// (chainid => totalValue)
    mapping(uint256 => uint256) public chainTotalValues;

    /*    ------------ Constructor ------------    */
    constructor(
        address _USDC,
        address _access,
        address _control,
        uint256 _chainID
    ) {
        USDC = IERC20(_USDC);
        authorityControl = IAuthorityControl(_access);
        strategyManager = IStrategyManager(_control);
        usdcAddr = _USDC;
        CHAINID = _chainID;
    }

    /*    -------------- Events --------------    */
    event DeleteData(uint256 chainID);
    event SetAxelar(address axelar);
    event SetLayerZero(address layerzero);
    event SetVault(address vault);

    /*    ------------- Modifiers ------------    */
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

    modifier onlyAxelarorLayerZero() {
        require(msg.sender == mainAxelar || msg.sender == mainLayerZero, "Not authorized");
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

    /// @notice Calculate the total amount of all on-chain asset prices.
    /// @return totalValue The total value.
    function calculateTotalChainValues()
        public
        view
        returns (uint256 totalValue)
    {
        for (uint256 i = 0; i < chainIDs.length; i++) {
            uint256 chainID = chainIDs[i];
            totalValue += chainTotalValues[chainID];
        }
        return totalValue;
    }

    /// @notice Calculate the total price of all assets on the specified chain.
    /// @param chainID The chain id of given chain.
    /// @return totalValue The total value.
    function getChainTotalValues(
        uint256 chainID
    ) public view returns (uint256) {
        uint256 totalValue = chainTotalValues[chainID];
        return totalValue;
    }

    /// @notice Calculate the total price of all assets on the specified strategy.
    /// @param chainID The chain id of given chain.
    /// @param strategyAddress The address of strategy.
    /// @return totalValue The total value.
    function getStrategyTotalValues(
        uint256 chainID,
        address strategyAddress
    ) public view returns (uint256) {
        uint256 totalValue = strategyTotalValues[chainID][strategyAddress];
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
    function strategiesStats() public onlyAdmin {
        _clearDataByChainId(CHAINID);
        _addVaultInfo();
        address[] memory activeAddresses = strategyManager
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
        _calculateAndStoreValues();
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

    /// @notice Receive strategy information from other chains.
    function updateFromStructs(Strategy[] calldata infos) public onlyAxelarorLayerZero {
        for (uint256 i = 0; i < infos.length; i++) {
            Strategy memory info = infos[i];
            address[] memory tokenAddrList = new address[](
                info.tokenInfo.length
            );
            for (uint256 j = 0; j < info.tokenInfo.length; j++) {
                tokenAddrList[j] = info.tokenInfo[j].tokenAddress;
            }
            tokenList[info.chainID][info.contractAddress] = tokenAddrList;
            for (uint256 j = 0; j < info.tokenInfo.length; j++) {
                chainStrategies[info.chainID][info.contractAddress][
                    info.tokenInfo[j].tokenAddress
                ] = info.tokenInfo[j];
            }

            if (!isContractAddressAdded(info.chainID, info.contractAddress)) {
                chainStrategyKeys[info.chainID].push(info.contractAddress);
            }

            if (!chainExists(info.chainID)) {
                chainIDs.push(info.chainID);
            }
        }
    }

    function calculateAndStoreValues() public onlyAxelarorLayerZero {
        _calculateAndStoreValues();
    }

    /// @notice Statistics on the price of stored tokens, 
    /// including locked tokens and negative growth tokens.
    function _calculateAndStoreValues() private {
        for (uint256 i = 0; i < chainIDs.length; i++) {
            uint256 chainID = chainIDs[i];
            uint256 totalChainValue = 0;
            address[] memory strategyAddresses = chainStrategyKeys[chainID];
            for (uint256 j = 0; j < strategyAddresses.length; j++) {
                address strategyAddress = strategyAddresses[j];
                IFarm.TokenInfo[] memory tokenInfos = getStrategyTokenInfo(
                    chainID,
                    strategyAddress
                );
                int256 totalStrategyValue = 0;
                for (uint256 k = 0; k < tokenInfos.length; k++) {
                    uint256 tokenAmount = tokenInfos[k].tokenAmount;
                    uint256 tokenValue = tokenInfos[k].tokenValue;

                    if(tokenInfos[k].negativeGrowth) {
                        totalStrategyValue -= int256(tokenAmount * tokenValue);
                    } else {
                        totalStrategyValue += int256(tokenAmount * tokenValue);
                    }
                }
                strategyTotalValues[chainID][strategyAddress] =
                    uint256(totalStrategyValue) /
                    10 ** 18;
                totalChainValue += uint256(totalStrategyValue) / 10 ** 18;
            }
            chainTotalValues[chainID] = totalChainValue;
        }
    }

    function setAxelar(address _axelar) public onlyAdmin {
        require(_axelar != address(0) && _axelar != mainAxelar, "Wrong address");
        mainAxelar = _axelar;
        emit SetAxelar(_axelar);
    }

    function setLayerZero(address _layerzero) public onlyAdmin {
        require(_layerzero != address(0) && _layerzero != mainLayerZero, "Wrong address");
        mainLayerZero = _layerzero;
        emit SetLayerZero(_layerzero);
    }

    function setVault(address _vault) public onlyAdmin {
        require(_vault != address(0) && _vault != vault, "Wrong address");
        vault = _vault;
        emit SetVault(_vault);
    }

    function clearDataByChainId(uint256 _chainID) public onlyAxelarorLayerZero {
        _clearDataByChainId(_chainID);
        emit DeleteData(_chainID);
    }

    /// @notice Clear statistics, called before each statistics. 
    function _clearDataByChainId(uint256 _chainID) private {
        address[] storage addresses = chainStrategyKeys[_chainID];

        for (uint256 j = 0; j < addresses.length; j++) {
            address contractAddress = addresses[j];
            address[] storage tokens = tokenList[_chainID][contractAddress];

            for (uint256 k = 0; k < tokens.length; k++) {
                delete chainStrategies[_chainID][contractAddress][tokens[k]];
            }
            delete tokenList[_chainID][contractAddress];
            delete strategyTotalValues[_chainID][contractAddress];
        }
        delete chainStrategyKeys[_chainID];
        delete chainTotalValues[_chainID];

        for (uint256 i = 0; i < chainIDs.length; i++) {
            if (chainIDs[i] == _chainID) {
                chainIDs[i] = chainIDs[chainIDs.length - 1];
                chainIDs.pop();
                break;
            }
        }
    }
}
