// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AxelarExecutable } from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import { IAxelarGasService } from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { ITokenStats } from "../interfaces/ITokenStats.sol";

/**
 * @title Tizi SubTokenAxelar
 * @author tizi.money
 * @notice
 *  SubTokenAxelar is deployed on other chains and is responsible 
 *  for counting and encapsulating the asset information on the chain 
 *  and sending it to the Base chain through Axelar.
 */
contract SubTokenAxelar is AxelarExecutable {
    IAxelarGasService public immutable gasService;
    ITokenStats public immutable tokenStats;

    string public destinationChain;
    string public destinationAddress;
    uint256 public sourceChainId;
    bytes public tokenCode;

    IAuthorityControl private _authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(
        address _gateway,
        address _gasService,
        address _tokenStats,
        string memory _destinationChain,
        string memory _destinationAddress,
        uint256 _sourceChainId,
        address _accessAddr
    ) AxelarExecutable(_gateway) {
        gasService = IAxelarGasService(_gasService);
        destinationChain = _destinationChain;
        destinationAddress = _destinationAddress;
        sourceChainId = _sourceChainId;
        _authorityControl = IAuthorityControl(_accessAddr);
        tokenStats = ITokenStats(_tokenStats);
    }

    /*    -------------- Events --------------    */
    event CrossChainCallInitiated(
        address indexed sender,
        string destinationChain,
        string destinationAddress,
        bytes payload
    );
    event TokenCodeUpdated(bytes newTokenCode, uint256 sourceChainId);

    /*    ------------- Modifiers ------------    */
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
    function getTokenCode() external view returns (bytes memory) {
        return tokenCode;
    }

    /*    ---------- Write Functions ----------    */
    function setTokenCode() external onlyAdmin {
        tokenStats.strategiesStats();
        tokenCode = abi.encode(tokenStats.getStrategiesForChain(sourceChainId));
        emit TokenCodeUpdated(tokenCode, sourceChainId);
    }

    function sendMessage(
        bytes calldata signedMessage
    ) public payable onlyAdmin {
        bytes memory messageBytes = abi.encode(signedMessage, tokenCode);
        bytes memory payload = messageBytes;
        gasService.payNativeGasForContractCall{value: msg.value}(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            msg.sender
        );
        gateway.callContract(destinationChain, destinationAddress, payload);
        emit CrossChainCallInitiated(
            msg.sender,
            destinationChain,
            destinationAddress,
            payload
        );
    }
}
