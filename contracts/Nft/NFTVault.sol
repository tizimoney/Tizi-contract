// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Tizi NFTVault
 * @author tizi.money
 * @notice
 *  NFTVault is used to store USDC in withdrawable NFTs. When some NFTs 
 *  become available for withdrawal, the corresponding amount of USDC
 *  will be transferred to NFTVault to prevent confusion with other funds.
 */
contract NFTVault is ReentrancyGuard {
    address private usdcAddr = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private helper;

    IAuthorityControl private authorityControl;

    constructor(
        address _accessAddr
    ) {
        authorityControl = IAuthorityControl(_accessAddr);
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

    event TrasferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event SetHelper(address newHelper);

    /// @notice Called by depositHelper, send a certain amount of USDC to the user.
    /// @param _to Receiver address.
    /// @param _amount The amount of USDC.
    /// @return IsSuccess.
    function sendToUser(
        address _to, 
        uint256 _amount
    ) external nonReentrant returns (bool) {
        require(msg.sender == helper, "Invalid caller address.");
        require(_amount > 0, "Amount must be greater than zero");
        require(IERC20(usdcAddr).balanceOf(address(this)) >= _amount, "No enough balance");
        IERC20(usdcAddr).transfer(_to, _amount);
        emit TrasferDetails(address(this), _to, _amount);
        return true;
    }

    function setHelper(address _helper) public onlyAdmin {
        require(_helper != helper && _helper != address(0), "Wrong address");
        helper = _helper;
        emit SetHelper(_helper);
    }
}