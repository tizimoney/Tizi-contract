// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";

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
 * @title Tizi CCTPv2
 * @author tizi.money
 * @notice
 *  Since the MainVault contract does not support CCTPV2, CCTPV2 exists in
 *  the form of a strategy. USDC needs to be transferred to this contract first,
 *  and then cross-chain to other chains from this contract.
 */
contract CCTPv2 {
    address public vault;
    
    address public usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// (vault address => is allowed to transfer though CCTP)
    mapping(address => bool) public vaultAddress;

    ITokenMessengerV2 public tokenMessenger;
    IAuthorityControl private authorityControl;
    ITransmitter private transmitter;

    event BridgeToInfo(uint256 dstDomain, address indexed to, uint256 amount);
    event BridgeInInfo(bytes32 messageHash);
    event ToVault(address indexed sender, uint256 amount, address indexed to);

    /*    ------------ Constructor ------------    */
    constructor(
        address _vault, 
        address _accessAddr,
        address _transmitter,
        address _tokenMessenger
    ) {
        vault = _vault;
        authorityControl = IAuthorityControl(_accessAddr);
        transmitter = ITransmitter(_transmitter);
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
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
    /// @param _receiver The address of subVault.
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
        require(vaultAddress[_receiver] == true, "Receiver is not vault");
        IERC20(usdc).approve(address(tokenMessenger), _amount);
        tokenMessenger.depositForBurn(
           _amount,
           _destDomain,
           addressToBytes32(_receiver),
           usdc,
           bytes32(0),
           _maxFee,
           _minFinalityThreshold
        );
        emit BridgeToInfo(_destDomain, _receiver, _amount);
    }

    function setVault(address[] memory _vault) external onlyAdmin {
        require(_vault.length > 0, "Please input at least one address");

        for(uint i = 0; i < _vault.length; ++i) {
            require(_vault[i] != address(0), "Wrong vault address");
            vaultAddress[_vault[i]] = true;
        }
    }

    function setTokenMessenger(address _tokenMessenger) external onlyAdmin {
        require(_tokenMessenger != address(0) && _tokenMessenger != address(tokenMessenger), "Wrong messenger address");
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
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
}
