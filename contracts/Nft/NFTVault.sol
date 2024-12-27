// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NFTVault is ReentrancyGuard {
    address private usdcAddr = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private helperAddr;
    bool public helperStatus = true;

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
    event SetHelper(address newHelper, bool newStatus);

    /// @notice Called by depositHelper, send a certain amount of USDC to the user.
    /// @param _to Receiver address.
    /// @param _amount The amount of USDC.
    /// @return IsSuccess.
    function sendToUser(
        address _to, 
        uint256 _amount
    ) external nonReentrant returns (bool) {
        require(helperStatus == false, "Uninitialized helper address.");
        require(msg.sender == helperAddr, "Invalid caller address.");
        require(_amount > 0, "Amount must be greater than zero");
        require(IERC20(usdcAddr).balanceOf(address(this)) >= _amount, "No enough balance");
        IERC20(usdcAddr).transfer(_to, _amount);
        emit TrasferDetails(address(this), _to, _amount);
        return true;
    }

    function setHelper(address _helperAddr) public onlyAdmin {
        require(helperStatus == true, "helper is already set");
        helperAddr = _helperAddr;
        helperStatus = false;
        emit SetHelper(_helperAddr, false);
    }

    function setHelperStatus(bool _helperstatus) public onlyAdmin {
        helperStatus = _helperstatus;
    }
}