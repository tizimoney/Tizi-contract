// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INFT {
    function mint(address to) external returns (uint256);

    function burn(uint256 tokenId) external returns (bool);

    function ownerOf(uint256 tokenId) external view returns (address);

    function ownerTokenIds(
        address owner
    ) external view returns (uint256[] memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function tokenByIndex(uint256 index) external view returns (uint256);
}
