// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";

/**
 * @title Tizi STTDAdapter
 * @author tizi.money
 * @notice
 *  STTDAdapter contract is used for stTD cross-chain, using LayerZeroV2.
 */
contract STTDAdapter is OFTAdapter {
    using OptionsBuilder for bytes;

    bytes public gasOptions;
    IAuthorityControl private _authorityControl;

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

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {
        _authorityControl = IAuthorityControl(_accessAddr);
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyAdmin {
        _setPeer(eid, peer);
    }

    function setBatchPeers(uint32[] memory eids, bytes32[] memory bytes32Addresses) public onlyAdmin {
        require(eids.length == bytes32Addresses.length, "eid and bytes32Addresses length are not same");
        for(uint256 i = 0; i < eids.length; ++i) {
            _setPeer(eids[i], bytes32Addresses[i]);
        }
    }

    function setOptions(uint128 gasLimit, uint128 msgValue) public onlyAdmin {
        bytes memory newOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, msgValue);
        gasOptions = newOptions;
    }
}