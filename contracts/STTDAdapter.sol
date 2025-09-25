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

    bytes public _options;
    IAuthorityControl private authorityControl;

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

    /*    ------------ Constructor ------------    */
    constructor(
        address _accessAddr,
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {
        authorityControl = IAuthorityControl(_accessAddr);
    }

    function setPeer(uint32 _eid, bytes32 _peer) public override onlyAdmin {
        _setPeer(_eid, _peer);
    }

    function setBtchPeers(uint32[] memory _eids, bytes32[] memory _peers) public onlyAdmin {
        require(_eids.length == _peers.length, "eid amd peer length are not same");
        for(uint256 i = 0; i < _eids.length; ++i) {
            _setPeer(_eids[i], _peers[i]);
        }
    }

    function setOptions(uint128 GAS_LIMIT, uint128 MSG_VALUE) public onlyAdmin {
        bytes memory new_options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT, MSG_VALUE);
        _options = new_options;
    }
}