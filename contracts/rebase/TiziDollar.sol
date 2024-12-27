// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LayerZeroRebaseTokenUpgradeable} from "../tokens/LayerZeroRebaseTokenUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ITokenStats} from "../interfaces/ITokenStats.sol";
import {IHelper} from "../interfaces/IHelper.sol";

contract TiziDollar is LayerZeroRebaseTokenUpgradeable {
    bool public helperStatus = true;
    address public helper;
    uint256 private rebaseNonce;
    uint256 public lastRebaseTime;
    address[] private projects;
    bool public tokenStatsStatus = true;
    address public tokenStats;

    /*    ------------ Constructor ------------    */
    constructor(
        address _endpoint,
        uint256 chainId,
        address _access
    ) LayerZeroRebaseTokenUpgradeable(_endpoint, chainId, _access) {}

    /*    -------------- Events --------------    */
    event SetHelper(address newHelper, bool newStatus);
    event SetTokenStats(address newTokenStats, bool newStatus);
    event RebaseAction(
        uint256 indexed ratioNumerator,
        uint256 indexed rebaseTime
    );
    event SendRebaseInfo(uint256 dstChainId, uint256 rebaseIndex);
    error UnsupportedChain(uint256 chainID);

    /*    ---------- Read Functions -----------    */
    function isRebaseDisabled(address _account) public view returns (bool) {
        return _isRebaseDisabled(_account);
    }

    function getRebaseNonce() public view returns (uint256) {
        return _rebaseNonce();
    }

    function getAllProjectAddresses() public view returns (address[] memory) {
        return projects;
    }

    function projectExists(address _project) public view returns (bool) {
        for (uint i = 0; i < projects.length; i++) {
            if (projects[i] == _project) {
                return true;
            }
        }
        return false;
    }

    function _isContract(address _account) private view returns (bool) {
        return _account.code.length > 0;
    }

    /*    ---------- Write Functions ----------    */

    function initialize() external initializer {
        __LayerZeroRebaseToken_init(msg.sender, "Tizi Dollar", "TD");
        _setRebaseIndex(1 ether, 0);
    }

    function mint(uint256 amount, address to) public {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        require(msg.sender == helper, "Not authorized");
        _mint(amount, to);
    }

    function _mint(uint256 amount, address to) private {
        require(to != address(0), "Invalid address");
        _update(address(0), to, amount);
    }

    function burn(uint256 amount, address from) public {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        require(msg.sender == helper, "Not authorized");
        _burn(amount, from);
    }

    function _burn(uint256 amount, address from) private {
        require(from != address(0), "Invalid address");
        require(balanceOf(from) >= amount, "Invalid amount");
        _update(from, address(0), amount);
    }

    function transfer(
        address to,
        uint value
    ) public override(IERC20, ERC20Upgradeable) returns (bool) {
        require(to != address(0), "invalid recipient");
        _update(msg.sender, to, value);
        return true;
    }

    function approve(
        address spender,
        uint value
    ) public override(IERC20, ERC20Upgradeable) returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        if (currentAllowance != type(uint256).max) {
            unchecked {
                _approve(msg.sender, spender, currentAllowance + value, true);
            }
        }
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override(IERC20, ERC20Upgradeable) returns (bool) {
        require(from != address(0), "Invalid sender");
        require(to != address(0), "Invalid receiver");
        require(balanceOf(from) >= value, "Insufficient balance");
        require(allowance(from, to) >= value, "Insufficient allowance");
        _spendAllowance(from, msg.sender, value);
        _update(from, to, value);
        return true;
    }

    /// @notice Send rebase information to other chains.
    /// @param dstChainId The chainID of the target chain.
    /// @param refundAddress The address of refund.
    /// @param zroPaymentAddress Zero address.
    /// @param adapterParams "0x".
    function sendRebaseInfo(
        uint16 dstChainId,
        address payable refundAddress,
        address zroPaymentAddress,
        bytes memory adapterParams
    ) public payable {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        onlyAdmin();
        _checkAdapterParams(
            dstChainId,
            PT_SEND_REBASE,
            adapterParams,
            NO_EXTRA_GAS
        );

        RebaseInfo memory info = RebaseInfo({
            rebaseIndex: rebaseIndex(),
            nonce: _rebaseNonce()
        });

        bytes memory lzPayload = abi.encode(PT_SEND_REBASE, msg.sender, info);
        _lzSend(
            dstChainId,
            lzPayload,
            refundAddress,
            zroPaymentAddress,
            adapterParams,
            msg.value
        );
        emit SendRebaseInfo(dstChainId, info.rebaseIndex);
    }

    /// @notice Rebase function, only called by admin.
    function rebase() public payable {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        onlyAdmin();
        uint256 asset = ITokenStats(tokenStats).calculateTotalChainValues();
        uint256 nftAmount = IHelper(helper).nftQueueUSDC();
        uint256 adjustedTotalAssets = asset - (nftAmount * (10 ** 12));
        uint256 totalTD = totalSupply();
        uint256 shares = sharesNum();
        uint256 poolTokenCount = ERC20Num();
        uint256 temp;
        if(totalTD < poolTokenCount) {
            temp = 0;
        } else {
            temp = totalTD - poolTokenCount;
        }
        uint256 netAsset = (adjustedTotalAssets * temp) /
            totalTD;
        uint256 newRebaseIndex = (netAsset * 1 ether) / shares;
        rebaseNonce++;
        uint256 _rebaseIndex;
        if(newRebaseIndex < rebaseIndex()) {
            _rebaseIndex = 0;
        } else {
            _rebaseIndex = newRebaseIndex - rebaseIndex();
        }
        uint256 treasuryAmount = (ERC20Num() *
            _rebaseIndex) / rebaseIndex(); 
        _setRebaseIndex(newRebaseIndex, rebaseNonce);
        lastRebaseTime = block.timestamp;
        if (treasuryAmount > 0) {
            _mint(treasuryAmount, treasuryAccount);
        }
        emit RebaseAction(newRebaseIndex, lastRebaseTime);
    }

    function addProject(address _project) public {
        require(
            _isContract(_project) == true,
            "The address must be a contract"
        );
        onlyAdmin();
        _disableRebase(_project, true);
        projects.push(_project);
    }

    function removeProject(address _project) public {
        onlyAdmin();
        for (uint i = 0; i < projects.length; i++) {
            if (projects[i] == _project) {
                projects[i] = projects[projects.length - 1];
                projects.pop();
                break;
            }
        }
    }

    function setHelper(address _helper) public {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        onlyAdmin();
        require(helperStatus == true, "helper exists");
        helper = _helper;
        helperStatus = false;
        emit SetHelper(_helper, false);
    }

    function setTokenStats(address _tokenStats) public {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        onlyAdmin();
        require(tokenStatsStatus == true, "tokenStats exists");
        tokenStats = _tokenStats;
        tokenStatsStatus = false;
        emit SetTokenStats(_tokenStats, false);
    }

    function setTokenStatsStatus(bool _isExist) public {
        if (isMainChain == false) {
            revert UnsupportedChain(block.chainid);
        }
        onlyAdmin();
        tokenStatsStatus = _isExist;
    }
}
