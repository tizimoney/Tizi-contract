// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {ITokenStats} from "../interfaces/ITokenStats.sol";

contract MainTokenAxelar is AxelarExecutable {
    using ECDSA for bytes32;

    IAuthorityControl private authorityControl;
    ITokenStats public immutable tokenStats;

    /*    ------------ Constructor ------------    */
    constructor(
        address _gateway,
        address _tokenStats,
        address _access
    ) AxelarExecutable(_gateway) {
        tokenStats = ITokenStats(_tokenStats);
        authorityControl = IAuthorityControl(_access);
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
        string calldata sourceChain,
        string calldata sourceAddress,
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
            authorityControl.hasRole(
                authorityControl.DEFAULT_ADMIN_ROLE(),
                signer
            ),
            "Not authorized"
        );
        ITokenStats.Strategy[] memory tokenInfo = abi.decode(
            message,
            (ITokenStats.Strategy[])
        );
        require(tokenInfo.length > 0, "TokenInfo array is empty");
        uint256 subCahinId = tokenInfo[0].chainID;
        tokenStats.clearDataByChainId(subCahinId);
        tokenStats.updateFromStructs(tokenInfo);
        tokenStats.calculateAndStoreValues();
        emit SignedMessageVerified(signer, hashMessage);
    }
}
