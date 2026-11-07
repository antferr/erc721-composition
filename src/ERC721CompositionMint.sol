// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Composition} from "./ERC721Composition.sol";

/// @title Example minting flow for the composition extension
/// @notice Not part of the interface: minting is left to each implementation. Whoever calls
///         {mint} supplies the constituents; the token goes to `to`.
/// @dev Order of operations: container creation (trusted code), declaration (state and
///      event), asset transfers (untrusted code), then the ERC-721 mint. Each transfer is
///      measured on the container, so the declared amount never exceeds what was received,
///      and the token exists only once its container holds the declared amounts: a recipient
///      that inspects it in `onERC721Received` already finds them there.
abstract contract ERC721CompositionMint is ERC721Composition {
    using SafeERC20 for IERC20;

    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 private _nextTokenId = 1;

    error NativeAmountMismatch(uint256 declared, uint256 sent);
    error InsufficientReceived(address asset, uint256 declared, uint256 received);
    error NativeTransferFailed();

    /// @notice Mints a token whose container receives `constituents` from the caller.
    /// @dev The native amount, if declared, must equal `msg.value`. ERC-20 constituents are
    ///      pulled from the caller, who must have approved this contract.
    function mint(address to, Constituent[] calldata constituents) external payable returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        address account = _createContainer(tokenId);
        _declareComposition(tokenId, account, constituents);

        uint256 nativeDeclared;
        for (uint256 i; i < constituents.length; ++i) {
            Constituent calldata constituent = constituents[i];
            if (constituent.asset == NATIVE_ASSET) {
                nativeDeclared = constituent.amount;
                continue;
            }
            IERC20 asset = IERC20(constituent.asset);
            uint256 before = asset.balanceOf(account);
            asset.safeTransferFrom(msg.sender, account, constituent.amount);
            uint256 received = asset.balanceOf(account) - before;
            if (received < constituent.amount) {
                revert InsufficientReceived(constituent.asset, constituent.amount, received);
            }
        }

        if (msg.value != nativeDeclared) revert NativeAmountMismatch(nativeDeclared, msg.value);
        if (nativeDeclared != 0) {
            uint256 before = account.balance;
            (bool ok,) = account.call{value: nativeDeclared}("");
            if (!ok) revert NativeTransferFailed();
            uint256 received = account.balance - before;
            if (received < nativeDeclared) revert InsufficientReceived(NATIVE_ASSET, nativeDeclared, received);
        }

        _safeMint(to, tokenId);
    }

    /// @dev Creates the container of `tokenId` and returns its address. It MUST be a contract
    ///      dedicated to this token and locked until the burn.
    function _createContainer(uint256 tokenId) internal virtual returns (address);
}
