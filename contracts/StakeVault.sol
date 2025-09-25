// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAuthorityControl} from "./interfaces/IAuthorityControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

    IAuthorityControl private authorityControl;

    
    event TrasferDetails(
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
        authorityControl = IAuthorityControl(_accessAddr);
        td = _td;
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

    function sendToUser(
        address _to, 
        uint256 _amount
    ) external nonReentrant returns (bool) {
        require(sTD != address(0), "Uninitialized staking pool address.");
        require(msg.sender == sTD, "Invalid caller address.");
        require(_amount > 0, "Amount must be greater than zero");
        require(IERC20(td).balanceOf(address(this)) >= _amount, "No enough balance");
        IERC20(td).transfer(_to, _amount);
        emit TrasferDetails(address(this), _to, _amount);
        return true;
    }

    function setSTD(address _sTD) external onlyAdmin {
        require(_sTD != address(0) && _sTD != sTD, "Wrong address");
        sTD = _sTD;
        emit SetNewSTD(_sTD);
    }

    function setTD(address _td) external onlyAdmin {
        require(_td != address(0) && _td != td, "Wrong address");
        td = _td;
        emit SetNewTD(_td);
    }
}