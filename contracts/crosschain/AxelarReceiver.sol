// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";

contract AxelarReceiver is AxelarExecutable {
    using ECDSA for bytes32;
    IAuthorityControl private immutable authorityControl;

    Info[] decodedArray;

    struct Info {
        uint8 code;
        address addr;
        uint256 amount;
        bytes32 role;
        string info;
        uint256 timestamp;
    }

    /*    ------------ Constructor ------------    */
    constructor(
        address _gateway,
        address _accessAddr
    ) AxelarExecutable(_gateway) {
        authorityControl = IAuthorityControl(_accessAddr);
    }

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

    /*    ---------- Read Functions -----------    */
    function getDecodedArray() public view returns (Info[] memory) {
        return decodedArray;
    }

    function getArrayLength() public view returns (uint256) {
        return decodedArray.length;
    }

    function getInfoByIndex(uint256 index) public view returns (Info memory) {
        require(index < decodedArray.length, "Index out of bounds");
        return decodedArray[index];
    }

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
        Info[] memory f = abi.decode(message, (Info[]));
        for (uint256 i = 0; i < f.length; i++) {
            decodedArray.push(f[i]);
        }
    }

    function removeInfoByIndex(uint256 index) public onlyAdmin {
        require(index < decodedArray.length, "Index out of bounds");
        decodedArray[index] = decodedArray[decodedArray.length - 1];
        decodedArray.pop();
    }

    function clearInfoArray() public onlyAdmin {
        delete decodedArray;
    }
}
