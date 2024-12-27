// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAuthorityControl {
    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function STRATEGIST_ROLE() external view returns (bytes32);

    function MANAGER_ROLE() external view returns (bytes32);
}
