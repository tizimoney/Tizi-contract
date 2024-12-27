// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OFTCoreUpgradeable} from "../layerzero/token/oft/v1/OFTCoreUpgradeable.sol";
import {IOFTCore} from "@layerzerolabs/solidity-examples/contracts/token/oft/v1/interfaces/IOFTCore.sol";
import {BytesLib} from "@layerzerolabs/solidity-examples/contracts/libraries/BytesLib.sol";
import {OFTUpgradeable} from "../layerzero/token/oft/v1/OFTUpgradeable.sol";

import {RebaseTokenMath} from "../lib/RebaseTokenMath.sol";
import {CrossChainRebaseTokenUpgradeable} from "./CrossChainRebaseTokenUpgradeable.sol";
import {RebaseTokenUpgradeable} from "./RebaseTokenUpgradeable.sol";
import {IAuthorityControl} from "../interfaces/IAuthorityControl.sol";

/**
 * @title LayerZeroRebaseTokenUpgradeable
 * @author Caesar LaVey
 * @notice This contract extends the functionality of `CrossChainRebaseTokenUpgradeable` and implements
 * `OFTUpgradeable`. It is designed to support cross-chain rebase token transfers and operations in a LayerZero network.
 *
 * @dev The contract introduces a new struct, `Message`, to encapsulate the information required for cross-chain
 * transfers. This includes shares, the rebase index, and the rebase nonce.
 *
 * The contract overrides various functions like `totalSupply`, `balanceOf`, and `_update` to utilize the base
 * functionalities from `RebaseTokenUpgradeable`.
 *
 * It also implements specific functions like `_debitFrom` and `_creditTo` to handle LayerZero specific operations.
 */
abstract contract LayerZeroRebaseTokenUpgradeable is
    CrossChainRebaseTokenUpgradeable,
    OFTUpgradeable
{
    using BytesLib for bytes;
    using RebaseTokenMath for uint256;

    address public treasuryAccount;

    IAuthorityControl public authorityControl;

    struct Message {
        uint256 shares;
        uint256 rebaseIndex;
        uint256 nonce;
    }

    struct RebaseInfo {
        uint256 rebaseIndex;
        uint256 nonce;
    }

    event SetTreasureAccount(address treasuryAccount);

    error CannotBridgeWhenOptedOut(address account);

    /**
     * @param endpoint The endpoint for Layer Zero operations.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address endpoint,
        uint256 chainId,
        address access
    ) OFTUpgradeable(endpoint) CrossChainRebaseTokenUpgradeable(chainId) {
        authorityControl = IAuthorityControl(access);
    }

    /**
     * @notice Initializes the LayerZeroRebaseTokenUpgradeable contract.
     * @dev This function is intended to be called once during the contract's deployment. It chains initialization logic
     * from `__LayerZeroRebaseToken_init_unchained`, `__CrossChainRebaseToken_init_unchained`, and `__OFT_init`.
     *
     * @param initialOwner The initial owner of the token contract.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     */
    function __LayerZeroRebaseToken_init(
        address initialOwner,
        string memory name,
        string memory symbol
    ) internal onlyInitializing {
        __LayerZeroRebaseToken_init_unchained();
        __CrossChainRebaseToken_init_unchained();
        __OFT_init(initialOwner, name, symbol);
    }

    function __LayerZeroRebaseToken_init_unchained()
        internal
        onlyInitializing
    {}

    function balanceOf(
        address account
    )
        public
        view
        override(IERC20, ERC20Upgradeable, RebaseTokenUpgradeable)
        returns (uint256)
    {
        return RebaseTokenUpgradeable.balanceOf(account);
    }

    function totalSupply()
        public
        view
        override(IERC20, ERC20Upgradeable, RebaseTokenUpgradeable)
        returns (uint256)
    {
        return RebaseTokenUpgradeable.totalSupply();
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20Upgradeable, RebaseTokenUpgradeable) {
        RebaseTokenUpgradeable._update(from, to, amount);
    }

    /**
     * @notice Debits a specified amount of tokens from an account.
     * @dev This function performs a series of checks and operations to debit tokens from an account. If the account
     * has not opted out of rebasing, it calculates the share equivalent of the specified amount and updates the
     * internal state accordingly. If the operation occurs on the main chain, the tokens are moved to the contract's
     * address. Otherwise, the tokens are burned.
     *
     * @param from The address from which the tokens will be debited.
     * @param amount The amount to debit from the account.
     * @return shares The share equivalent of the debited amount.
     */
    function _debitFrom(
        address from,
        uint16,
        bytes memory,
        uint256 amount
    ) internal override returns (uint256 shares) {
        shares = _transferableShares(amount, from);
        if (from != msg.sender) {
            _spendAllowance(from, msg.sender, amount);
        }
        if (isMainChain) {
            _update(from, address(this), amount);
        } else {
            _update(from, address(0), amount);
        }
    }

    /**
     * @notice Credits a specified number of tokens to an account.
     *
     * @param to The address to which the shares will be credited.
     * @param shares The number of shares to credit to the account.
     * @return amount The token equivalent of the credited shares.
     */
    function _creditTo(
        uint16,
        address to,
        uint256 shares
    ) internal override returns (uint256 amount) {
        amount = shares.toTokens(rebaseIndex());
        if (isMainChain) {
            _update(address(this), to, amount);
        } else {
            _update(address(0), to, amount);
        }
        return amount;
    }

    function onlyAdmin() internal view {
        require(
            authorityControl.hasRole(
                authorityControl.DEFAULT_ADMIN_ROLE(),
                msg.sender
            ),
            "Not authorized"
        );
    }

    function estimateRebaseFee(
        uint16 dstChainId,
        bool useZro,
        bytes memory adapterParams
    ) public view returns (uint256 nativeFee, uint256 zroFee) {
        RebaseInfo memory info = RebaseInfo({
            rebaseIndex: rebaseIndex(),
            nonce: _rebaseNonce()
        });
        bytes memory payload = abi.encode(PT_SEND_REBASE, msg.sender, info);
        return
            lzEndpoint.estimateFees(
                dstChainId,
                address(this),
                payload,
                useZro,
                adapterParams
            );
    }

    function estimateSendFee(
        uint16 dstChainId,
        bytes calldata toAddress,
        uint256 amount,
        bool useZro,
        bytes calldata adapterParams
    )
        public
        view
        override(OFTCoreUpgradeable, IOFTCore)
        returns (uint256 nativeFee, uint256 zroFee)
    {
        Message memory message = Message({
            shares: _transferableShares(amount, msg.sender),
            rebaseIndex: rebaseIndex(),
            nonce: _rebaseNonce()
        });
        bytes memory payload = abi.encode(
            PT_SEND,
            msg.sender,
            msg.sender,
            msg.sender,
            message
        );
        return
            lzEndpoint.estimateFees(
                dstChainId,
                address(this),
                payload,
                useZro,
                adapterParams
            );
    }

    function send(
        address _from,
        uint16 _dstChainId,
        bytes memory _toAddress,
        uint256 _amount,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes memory _adapterParams
    ) public payable {
        _send(
            _from,
            _dstChainId,
            _toAddress,
            _amount,
            _refundAddress,
            _zroPaymentAddress,
            _adapterParams
        );
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64,
        bytes memory _payload
    ) internal virtual override {
        uint16 packetType;
        assembly {
            packetType := mload(add(_payload, 32))
        }
        if (packetType == PT_SEND) {
            _sendAck(_srcChainId, _srcAddress, 0, _payload);
        } else if (packetType == PT_SEND_REBASE) {
            _sendRebaseAck(_srcChainId, _srcAddress, 0, _payload);
        } else {
            revert("OFTCore: unknown packet type");
        }
    }

    /**
     * @notice Initiates the sending of tokens to another chain.
     * @dev This function prepares a message containing the shares, rebase index, and nonce. It then uses LayerZero's
     * send functionality to send the tokens to the destination chain. The function checks adapter parameters and emits
     * a `SendToChain` event upon successful execution.
     *
     * @param from The address from which tokens are sent.
     * @param dstChainId The destination chain ID.
     * @param toAddress The address on the destination chain to which tokens will be sent.
     * @param amount The amount of tokens to send.
     * @param refundAddress The address for any refunds.
     * @param zroPaymentAddress The address for ZRO payment.
     * @param adapterParams Additional parameters for the adapter.
     */
    function _send(
        address from,
        uint16 dstChainId,
        bytes memory toAddress,
        uint256 amount,
        address payable refundAddress,
        address zroPaymentAddress,
        bytes memory adapterParams
    ) internal override {
        if (optedOut(from)) {
            // tokens cannot be bridged if the account has opted out of rebasing
            revert CannotBridgeWhenOptedOut(from);
        }

        _checkAdapterParams(dstChainId, PT_SEND, adapterParams, NO_EXTRA_GAS);

        Message memory message = Message({
            shares: _debitFrom(from, dstChainId, toAddress, amount),
            rebaseIndex: rebaseIndex(),
            nonce: _rebaseNonce()
        });

        emit SendToChain(
            dstChainId,
            from,
            toAddress,
            message.shares.toTokens(message.rebaseIndex)
        );

        bytes memory lzPayload = abi.encode(
            PT_SEND,
            msg.sender,
            from,
            toAddress,
            message
        );
        _lzSend(
            dstChainId,
            lzPayload,
            refundAddress,
            zroPaymentAddress,
            adapterParams,
            msg.value
        );
    }

    /**
     * @notice Acknowledges the receipt of tokens from another chain and credits the correct amount to the recipient's
     * address.
     * @dev Upon receiving a payload, this function decodes it to extract the destination address and the message
     * content, which includes shares, rebase index, and nonce. If the current chain is not the main chain, it updates
     * the rebase index and nonce accordingly. Then, it credits the token shares to the recipient's address and emits a
     * `ReceiveFromChain` event.
     *
     * The function assumes that `_setRebaseIndex` handles the correctness of the rebase index and nonce update.
     *
     * @param srcChainId The source chain ID from which tokens are received.
     * @param srcAddressBytes The address on the source chain from which the message originated.
     * @param payload The payload containing the encoded destination address and message with shares, rebase index, and
     * nonce.
     */
    function _sendAck(
        uint16 srcChainId,
        bytes memory srcAddressBytes,
        uint64,
        bytes memory payload
    ) internal override {
        (
            ,
            address initiator,
            address from,
            bytes memory toAddressBytes,
            Message memory message
        ) = abi.decode(payload, (uint16, address, address, bytes, Message));

        if (!isMainChain) {
            if (message.nonce > _rebaseNonce()) {
                _setRebaseIndex(message.rebaseIndex, message.nonce);
            }
        }

        address src = srcAddressBytes.toAddress(0);
        address to = toAddressBytes.toAddress(0);
        uint256 amount;

        amount = _creditTo(srcChainId, to, message.shares);

        _tryNotifyReceiver(srcChainId, initiator, from, src, to, amount);

        emit ReceiveFromChain(srcChainId, to, amount);
    }

    function _sendRebaseAck(
        uint16 srcChainId,
        bytes memory,
        uint64,
        bytes memory payload
    ) internal {
        (, , RebaseInfo memory rebaseInfo) = abi.decode(
            payload,
            (uint16, address, RebaseInfo)
        );
        if (!isMainChain) {
            uint256 treasuryAmount = (ERC20Num() *
                (rebaseInfo.rebaseIndex - rebaseIndex())) / rebaseIndex();
            if (treasuryAmount > 0) {
                _update(address(0), treasuryAccount, treasuryAmount);
            }
            if (rebaseInfo.nonce > _rebaseNonce()) {
                _setRebaseIndex(rebaseInfo.rebaseIndex, rebaseInfo.nonce);
            }
        }

        emit ReceiveFromChain(
            srcChainId,
            treasuryAccount,
            rebaseInfo.rebaseIndex
        );
    }

    function setTreasuryAccount(address _account) public {
        onlyAdmin();
        _disableRebase(_account, true);
        treasuryAccount = _account;
        emit SetTreasureAccount(_account);
    }
}
