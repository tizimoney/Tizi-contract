// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface IWrappedTokenBridge {
    struct CallParams {
        address payable refundAddress;
        address zroPaymentAddress;
    }

    function estimateBridgeFee(
        bool useZro, 
        bytes calldata adapterParams
    ) external view returns (uint nativeFee, uint zroFee);

    function bridge(
        address token, 
        uint amountLD, 
        address to, 
        CallParams calldata callParams, 
        bytes memory adapterParams
    ) external payable;
}

struct TokenInfo {
    address tokenAddress;
    uint256 timestamp;
    bool negativeGrowth;
    uint256 tokenAmount;
    uint256 tokenValue;
}

struct CheckInfo {
    uint256 amount;
    bool negativeGrowth;
    uint256 timestamp;
}

struct EarlierProfits {
    CheckInfo[] checkList;
}

/**
 * @title Tizi BridgeUSDCEtherLink
 * @author tizi.money
 * @notice
 *  Since CCTP does not support the EtherLink chain, LayerZeroV1 is used to
 *  complete the USDC cross-chain. First, USDC is transferred to this contract,
 *  and then sent from this contract to the EtherLink chain.
 */
contract BridgeUSDCEtherLink {
    address public vault;
    
    address public usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public wrappedTokenBridge;
    address public etherLinkVault;
    bytes public options;

    IAuthorityControl private authorityControl;

    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event ToVault(address indexed sender, uint256 amount, address indexed to);

    /*    ------------ Constructor ------------    */
    constructor(
        address _vault, 
        address _accessAddr,
        address _wrappedTokenBridge
    ) {
        vault = _vault;
        authorityControl = IAuthorityControl(_accessAddr);
        wrappedTokenBridge = _wrappedTokenBridge;
        setOptions(1, 125000);
    }

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

    /// @notice Get information about all assets, including quantity, price, 
    /// whether negative growth, whether locked, etc. 
    /// This method is used for rebase. All profits are subject to a certain tax, 
    /// and the amount returned is the amount after tax.
    /// @return Tokeninfo.
    function getTokenInfo()
        external
        view
        returns (TokenInfo[] memory)
    {
        EarlierProfits[] memory checkArray = check();
        CheckInfo[] memory usdcInfos = checkArray[0].checkList;
        TokenInfo[] memory tokenInfo = new TokenInfo[](1);

        tokenInfo[0] = TokenInfo({
            tokenAddress: usdc,
            timestamp: 0,
            negativeGrowth: false,
            tokenAmount: usdcInfos[0].amount * 
                (10 ** (18 - IERC20(usdc).decimals())),
            tokenValue: (10 ** 18)
        });
        return tokenInfo;
    }

    /// @notice To obtain information on all assets for dev, 
    /// including principal and profit, the amount shown is accurate, 
    /// the amount is before tax.
    /// @return Tokeninfo.
    function check() public view returns (EarlierProfits[] memory) {
        EarlierProfits[] memory earlierProfitsList = new EarlierProfits[](1);
        uint256 usdcValue = IERC20(usdc).balanceOf(address(this));
        CheckInfo memory usdcInfo = CheckInfo(usdcValue, false, 0);
        earlierProfitsList[0] = EarlierProfits(new CheckInfo[](1));
        earlierProfitsList[0].checkList[0] = usdcInfo;
        return earlierProfitsList;
    }

    function addressToBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function getTransferFee() public view returns (uint256) {
        (uint256 nativeFee, ) = IWrappedTokenBridge(wrappedTokenBridge).estimateBridgeFee(false, options);
        return nativeFee;
    }

    /*    ---------- Write Functions ----------    */
    function bridgeOut(
        uint256 _amount
    ) public payable onlyManager {
        if(_amount == 0 || _amount > IERC20(usdc).balanceOf(address(this))) {
            _amount = IERC20(usdc).balanceOf(address(this));
        }
        IERC20(usdc).approve(wrappedTokenBridge, _amount);

        IWrappedTokenBridge.CallParams memory callParams = IWrappedTokenBridge.CallParams({
            refundAddress: payable(address(this)),
            zroPaymentAddress: address(0)
        });
        IWrappedTokenBridge(wrappedTokenBridge).bridge{value: msg.value}(
            usdc, 
            _amount, 
            etherLinkVault, 
            callParams, 
            options
        );
        emit BridgeToInfo(184, etherLinkVault, _amount);
    }

    function setOptions(uint16 _version, uint256 _value) public onlyAdmin {
        options = abi.encodePacked(_version, _value);
    }

    function setEtherLinkVault(address _vault) external onlyAdmin {
        require(_vault != address(0) && _vault != etherLinkVault, "Wrong vault address");
        etherLinkVault = _vault;
    }

    function setWrappedTokenBridge(address _wrappedTokenBridge) external onlyAdmin {
        require(_wrappedTokenBridge != address(0) && _wrappedTokenBridge != wrappedTokenBridge, "Wrong address");
        wrappedTokenBridge = _wrappedTokenBridge;
    }

    /// @notice Transfer USDC to vault.
    /// @param _amount The amount of USDC to transfer.
    function toVault(uint256 _amount) external {
        require(msg.sender == vault, "sender must be vault");
        require(IERC20(usdc).balanceOf(address(this)) >= _amount,
            "_amount is larger than balance");
        
        IERC20(usdc).transfer(vault, _amount);
        emit ToVault(msg.sender, _amount, vault);
    }

    fallback() external payable{}
    receive() external payable {}
}
