// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TLT is ERC20, Ownable {
    address public lottery;

    constructor() ERC20("Tizi Lottery Token", "TLT") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) public {
        require(msg.sender == lottery);
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) public {
        require(msg.sender == lottery);
        _burn(account, amount);
    }

    function setLottery(address _lottery) external onlyOwner {
        lottery = _lottery;
    }
}