// SPDX-License-Identifier: MIT
import {IERC20} from "./IERC20.sol";

pragma solidity ^0.8.20;

interface ISharedStructs {
    struct SwapDescriptionV2 {
        IERC20 srcToken;
        IERC20 dstToken;
        address[] srcReceivers; // transfer src token to these addresses, default
        uint256[] srcAmounts;
        address[] feeReceivers;
        uint256[] feeAmounts;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
        bytes permit;
    }
    
    struct SwapExecutionParams {
        address callTarget; // call this address
        address approveTarget; // approve this address if _APPROVE_FUND set
        bytes targetData;
        SwapDescriptionV2 desc;
        bytes clientData;
    }
    
    struct ExchangeRequest {
        address from;
        uint256 amountIn;
        address[] to;
        ExchangeRoute[] exchangeRoutes;
        uint256[] slippage;
        uint256[] amountOutExpected;
    }

    struct ExchangeRoute {
        address from;
        uint256 parts;
        Swap[] swaps;
    }

    struct Swap {
        address to;
        uint256 part;
        address addr;
        bytes32 family;
        bytes data;
    }
}
