// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IAuthorityControl } from "./interfaces/IAuthorityControl.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Tizi StakeVault
 * @author tizi.money
 * @notice
 *  StakeVault is used to store TD in pending state and
 *  is controlled by the stake pool.
 */
contract StakeVault is ReentrancyGuard {
    address public sTD;
    address public td;

    IAuthorityControl private _authorityControl;

    event TransferDetails(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event SetNewSTD(address newSTD);
    event SetNewTD(address newTD);

    constructor(
        address _accessAddr,
        address _td
    ) {
        _authorityControl = IAuthorityControl(_accessAddr);
        td = _td;
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

    function sendToUser(
        address to,
        uint256 amount
    ) external nonReentrant returns (bool) {
        require(sTD != address(0), "Uninitialized staking pool address.");
        require(msg.sender == sTD, "Invalid caller address.");
        require(amount > 0, "Amount must be greater than zero");
        require(IERC20(td).balanceOf(address(this)) >= amount, "No enough balance");
        IERC20(td).transfer(to, amount);
        emit TransferDetails(address(this), to, amount);
        return true;
    }

    function setSTD(address newSTD) external onlyAdmin {
        require(newSTD != address(0) && newSTD != sTD, "Wrong address");
        sTD = newSTD;
        emit SetNewSTD(newSTD);
    }

    function setTD(address newTD) external onlyAdmin {
        require(newTD != address(0) && newTD != td, "Wrong address");
        td = newTD;
        emit SetNewTD(newTD);
    }
}