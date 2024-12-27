// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {IAxelarGasService} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";

contract AxelarSender is AxelarExecutable {
    IAxelarGasService private immutable gasService;
    bytes infoBytes;
    IAuthorityControl private immutable authorityControl;

    struct Info {
        uint8 code;
        address addr;
        uint256 amount;
        bytes32 role;
        string info;
        uint256 timestamp;
    }

    Info[] infoArray;

    /*    ------------ Constructor ------------    */
    constructor(
        address _gateway,
        address _gasService,
        address _accessAddr
    ) AxelarExecutable(_gateway) {
        gasService = IAxelarGasService(_gasService);
        authorityControl = IAuthorityControl(_accessAddr);
    }

    /*    -------------- Events --------------    */
    event InfoBytesUpdated(address sender, bytes infoBytes);

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
    function getInfoBytes() external view returns (bytes memory) {
        return infoBytes;
    }

    function getAllInfo() public view returns (Info[] memory) {
        return infoArray;
    }

    function getArrayLength() public view returns (uint256) {
        return infoArray.length;
    }

    function getInfoByIndex(uint256 index) public view returns (Info memory) {
        require(index < infoArray.length, "Index out of bounds");
        return infoArray[index];
    }

    /*    ---------- Write Functions ----------    */
    function setInfoBytes() external onlyAdmin {
        infoBytes = abi.encode(infoArray);
        _clearInfoArray();
        emit InfoBytesUpdated(msg.sender, infoBytes);
    }

    function sendMessage(
        bytes calldata _signedMessage,
        string memory _destinationChain,
        string memory _destinationAddress
    ) external payable onlyAdmin {
        bytes memory messageBytes = abi.encode(_signedMessage, infoBytes);
        bytes memory payload = messageBytes;
        gasService.payNativeGasForContractCall{value: msg.value}(
            address(this),
            _destinationChain,
            _destinationAddress,
            payload,
            msg.sender
        );
        gateway.callContract(_destinationChain, _destinationAddress, payload);
    }

    function arrayInit(
        uint8 _code,
        address _addr,
        uint256 _amount,
        bytes32 _role,
        string memory _info
    ) public onlyAdmin {
        infoArray.push(
            Info(_code, _addr, _amount, _role, _info, block.timestamp)
        );
    }

    function removeInfoByIndex(uint256 index) public onlyAdmin {
        require(index < infoArray.length, "Index out of bounds");
        infoArray[index] = infoArray[infoArray.length - 1];
        infoArray.pop();
    }

    function _clearInfoArray() private {
        delete infoArray;
    }
}
