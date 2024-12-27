// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

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
