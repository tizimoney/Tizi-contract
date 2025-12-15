// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IAuthorityControl } from "../interfaces/IAuthorityControl.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Tizi NFTVault
 * @author tizi.money
 * @notice
 *  NFTVault is used to store USDC in withdrawable NFTs. When some NFTs
 *  become available for withdrawal, the corresponding amount of USDC
 *  will be transferred to NFTVault to prevent confusion with other funds.
 */
contract NFTVault is ReentrancyGuard {
    address public usdcAddr = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private _helper;

    IAuthorityControl private _authorityControl;

    constructor(
        address _accessAddr
    ) {
        _authorityControl = IAuthorityControl(_accessAddr);
    }

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

    event TransferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event SetHelper(address newHelper);

    /// @notice Called by depositHelper, send a certain amount of USDC to the user.
    /// @param to Receiver address.
    /// @param amount The amount of USDC.
    /// @return IsSuccess.
    function sendToUser(
        address to,
        uint256 amount
    ) external nonReentrant returns (bool) {
        require(msg.sender == _helper, "Invalid caller address.");
        require(amount > 0, "Amount must be greater than zero");
        require(IERC20(usdcAddr).balanceOf(address(this)) >= amount, "No enough balance");
        IERC20(usdcAddr).transfer(to, amount);
        emit TransferDetails(address(this), to, amount);
        return true;
    }

    function setHelper(address newHelper) public onlyAdmin {
        require(newHelper != _helper && newHelper != address(0), "Wrong address");
        _helper = newHelper;
        emit SetHelper(newHelper);
    }
}