// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { ITokenStats } from "../interfaces/ITokenStats.sol";

/**
 * @title Tizi SubTokenLayerZero
 * @author tizi.money
 * @notice
 *  SubTokenLayerZero is deployed on other chains and is responsible 
 *  for counting and encapsulating the asset information on the chain 
 *  and sending it to the Base chain through LayerZero.
 */
contract SubTokenLayerZero is OApp {
    using OptionsBuilder for bytes;

    bytes public tokenCode;
    uint256 public sourceChainId;
    bytes public gasOptions;
    ITokenStats public immutable tokenStats;

    IAuthorityControl private _authorityControl;

    event MessageSent(bytes payload , uint32 dstEid);
    event TokenCodeUpdated(bytes newTokenCode, uint256 sourceChainId);

    constructor(
        address _endpoint,
        address _owner,
        address _tokenStats,
        uint256 _sourceChainId,
        address _accessAddr
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        tokenStats = ITokenStats(_tokenStats);
        sourceChainId = _sourceChainId;
        _authorityControl = IAuthorityControl(_accessAddr);
    }

    // Some arbitrary data you want to deliver to the destination chain!
    
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

    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function bytes32ToAddress(bytes32 bytes32Address) public pure returns (address) {
        return address(uint160(uint256(bytes32Address)));
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyAdmin {
        _setPeer(eid, peer);
    }

    function setOptions(uint128 gasLimit, uint128 msgValue) public onlyAdmin {
        bytes memory newOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, msgValue);
        gasOptions = newOptions;
    }

    function quote(
        uint32 dstEid,
        string memory signedMessage,
        bool payInLzToken
    ) public view returns (MessagingFee memory) {
        bytes memory messageBytes = abi.encode(signedMessage, tokenCode);
        bytes memory payload = messageBytes;
        MessagingFee memory fee = _quote(dstEid, payload, gasOptions, payInLzToken);
        return fee;
    }

    function send(
        uint32 dstEid,
        bytes calldata signedMessage
    ) external payable onlyAdmin {
        bytes memory messageBytes = abi.encode(signedMessage, tokenCode);
        bytes memory payload = messageBytes;

        _lzSend(
            dstEid,
            payload,
            gasOptions,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit MessageSent(payload, dstEid);
    }

    /**
     * @dev Called when data is received from the protocol. It overrides the equivalent function in the parent contract.
     * Protocol messages are defined as packets, comprised of the following parameters.
     * @param origin A struct containing information about where the packet came from.
     * @param guid A global unique identifier for tracking the packet.
     * @param payload Encoded message.
     */
    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address,  // Executor address as specified by the OApp.
        bytes calldata  // Any extra data or options to trigger on receipt.
    ) internal override {
        // Decode the payload to get the message
        // In this case, type is string, but depends on your encoding!
        //data = abi.decode(payload, (string));
    }
}