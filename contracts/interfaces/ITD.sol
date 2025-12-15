// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITD {
    function rebaseIndex() external view returns (uint256 index);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function mint(uint256 amount, address to) external;

    function burn(uint256 amount, address from) external;

    function mintForYield(uint256 amount) external;

    function burnForYield(uint256 amount) external;

    function mintForProfitRecipient(address profitRecipient, uint256 profit) external;

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function approve(address spender, uint value) external returns (bool);

    function getRebaseNonce() external view returns (uint256);

    function helper() external view returns (address);
}
