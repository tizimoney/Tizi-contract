// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITD} from "../interfaces/ITD.sol";

contract LP {
    address public me;
    ITD public td;

    /*    ------------ Constructor ------------    */
    constructor(address _me, address _td) {
        me = _me;
        td = ITD(_td);
    }

    function transferToMe() public {
        uint256 amount = td.balanceOf(address(this));
        td.transfer(me, amount);
    }
}
