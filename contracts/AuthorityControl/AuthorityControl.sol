// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title Tizi AuthorityControl
 * @author tizi.money
 * @notice
 *  AuthorityControl is used for authority control, and there are three roles.
 *  Admin can change the parameters of the project, send messages, and
 *  cross-chain tokens.
 *  Manager is responsible for transferring and using funds.
 *  Strategist is responsible for making changes to certain external strategies.
 */
contract AuthorityControl is AccessControl {
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /*    ------------ Constructor ------------    */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*    ---------- Write Functions ----------    */
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }
}
