// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { ITokenStats } from "../interfaces/ITokenStats.sol";

/**
 * @title Tizi MainTokenLayerZero
 * @author tizi.money
 * @notice
 *  MainTokenLayerZero is deployed on the Base chain. When messages are 
 *  sent across chains through LayerZero, MainTokenLayerZero will receive 
 *  information from other chains, parse it and store it.
 */
contract MainTokenLayerZero is OApp {
    using ECDSA for bytes32;

    ITokenStats public immutable tokenStats;
    bytes public tokenInfoData;

    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _endpoint,
        address _owner,
        address _tokenStats,
        address _access
    )  OApp(_endpoint, _owner) Ownable(_owner) {
        tokenStats = ITokenStats(_tokenStats);
        _authorityControl = IAuthorityControl(_access);
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

    /*    -------------- Events --------------    */
    event SignedMessageVerified(
        address indexed signer,
        bytes32 indexed messageHash
    );

    /*    ---------- Read Functions -----------    */
    function toEthSignedMessageHash(
        bytes32 hash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
            );
    }

    /*    ---------- Write Functions ----------    */
    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function bytes32ToAddress(bytes32 bytes32Address) public pure returns (address) {
        return address(uint160(uint256(bytes32Address)));
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
        tokenInfoData = payload;
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
        ITokenStats.Strategy[] memory tokenInfo = abi.decode(
            message,
            (ITokenStats.Strategy[])
        );
        require(tokenInfo.length > 0, "TokenInfo array is empty");
        uint256 subChainId = tokenInfo[0].chainID;
        tokenStats.clearDataByChainId(subChainId);
        tokenStats.updateFromStructs(tokenInfo);
        tokenStats.calculateAndStoreValues();
        emit SignedMessageVerified(signer, hashMessage);
    }

    /// For manual execution.
    function execute() public onlyAdmin {
        (bytes memory signedMessage, bytes memory message) = abi.decode(
            tokenInfoData,
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
        ITokenStats.Strategy[] memory tokenInfo = abi.decode(
            message,
            (ITokenStats.Strategy[])
        );
        require(tokenInfo.length > 0, "TokenInfo array is empty");
        uint256 subChainId = tokenInfo[0].chainID;
        tokenStats.clearDataByChainId(subChainId);
        tokenStats.updateFromStructs(tokenInfo);
        tokenStats.calculateAndStoreValues();
        emit SignedMessageVerified(signer, hashMessage);
    }
}