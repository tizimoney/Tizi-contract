// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IHelper} from "../interfaces/IHelper.sol";

/**
 * @title Tizi TUWT
 * @author tizi.money
 * @notice
 *  TUWT is Tizi.money's NFT, which is mainly used as a withdrawal
 *  voucher. When a user withdraws money and there is not enough funds
 *  in the MainVault, an NFT will be minted for the user, recording
 *  the amount to be withdrawn. When there are sufficient funds, the NFT
 *  will be made available in order.
 */
contract TUWT is ERC721Enumerable {
    using Strings for uint256;
    uint256 private _nextTokenId;
    address public helper;
    IAuthorityControl private immutable authorityControl;

    /*    ------------ Constructor ------------    */
    constructor(address _access) ERC721("Tizi User Withdraw Token", "TUWT") {
        authorityControl = IAuthorityControl(_access);
    }

    /*    -------------- Events --------------    */
    event SetHelper(address newHelper);

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
    function ownerTokenIds(
        address owner
    ) public view returns (uint256[] memory) {
        uint256 balance = ERC721.balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
        return tokenIds;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        IHelper.WithdrawNFT memory withdrawNFT = IHelper(helper).withdrawNFTs(
            tokenId
        );
        return
            string(
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"tokenId":"',
                            toString(withdrawNFT.tokenId),
                            '", "queueId":"',
                            toString(withdrawNFT.queueId),
                            '", "mintTime":"',
                            toString(withdrawNFT.mintTime),
                            '", "amount":"',
                            toString(withdrawNFT.amount),
                            '"}'
                        )
                    )
                )
            );
    }

    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /*    ---------- Write Functions ----------    */
    function mint(address _to) external returns (uint256 tokenId) {
        require(msg.sender == helper, "Not authorized");
        tokenId = _nextTokenId;
        _nextTokenId++;
        _safeMint(_to, tokenId);
    }

    function burn(uint256 _tokenId) external returns (bool) {
        require(msg.sender == helper, "Not authorized");
        _burn(_tokenId);
        return true;
    }

    function setHelper(address _helper) external onlyAdmin {
        require(_helper != helper && _helper != address(0), "Wrong address");
        helper = _helper;
        emit SetHelper(_helper);
    }
}
