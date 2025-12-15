// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AxelarExecutable } from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { ITokenStats } from "../interfaces/ITokenStats.sol";

/**
 * @title Tizi MainTokenAxelar
 * @author tizi.money
 * @notice
 *  MainTokenAxelar is deployed on the Base chain. When messages are 
 *  sent across chains through Axelar, MainTokenAxelar will receive 
 *  information from other chains, parse it and store it.
 */
contract MainTokenAxelar is AxelarExecutable {
    using ECDSA for bytes32;

    ITokenStats public immutable tokenStats;
    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _gateway,
        address _tokenStats,
        address _access
    ) AxelarExecutable(_gateway) {
        tokenStats = ITokenStats(_tokenStats);
        _authorityControl = IAuthorityControl(_access);
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
    function _execute(
        string calldata,
        string calldata,
        bytes calldata _payload
    ) internal override {
        (bytes memory signedMessage, bytes memory message) = abi.decode(
            _payload,
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
