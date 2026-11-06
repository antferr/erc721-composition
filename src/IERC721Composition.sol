// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ERC-721 composition extension (draft interface)
/// @notice Every conforming token holds its constituents in a container dedicated to that
///         token. While the token exists nothing leaves the container; after the burn only
///         the address returned by `burnedBy` (ERC-8423) can move the assets out. The
///         declared composition is a minimum: the container may hold more, never less,
///         except for assets whose own contract can reduce a holder's balance.
/// @dev The ERC-165 identifier for this interface is 0xd60a6c7e.
///      Minting and burning are left to each implementation.
interface IERC721Composition /* is IERC721, IERC721BurnRecord, IERC165 */ {
    /// @notice One constituent of a token.
    /// @param asset  The ERC-20 token contract, or 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    ///               (ERC-7528) for the chain's native asset.
    /// @param amount The declared amount, in the asset's smallest unit. Never zero.
    struct Constituent {
        address asset;
        uint256 amount;
    }

    /// @notice Emitted exactly once for each token, in the transaction that mints it,
    ///         including tokens created in batch. Carries the same data that
    ///         `compositionOf` and `compositionAccountOf` return for `tokenId`.
    event CompositionDeclared(
        uint256 indexed tokenId,
        address indexed account,
        bytes4 accountType,
        bytes accountData,
        Constituent[] constituents
    );

    /// @notice Returns the declared composition of `tokenId`, fixed at mint.
    /// @dev Sorted by strictly increasing asset address, so each asset appears once.
    ///      Returns the same value after the burn. Returns an empty array for a token that
    ///      was never minted: an empty composition means "not declared", never
    ///      "zero guaranteed". Does not revert.
    function compositionOf(uint256 tokenId) external view returns (Constituent[] memory constituents);

    /// @notice Returns the container that holds the constituents of `tokenId`, its type and
    ///         the data a third party needs to verify it, all fixed at mint.
    /// @dev `accountType` is the ERC-165 identifier of the container's interface, which the
    ///      container confirms through `supportsInterface`. For an ERC-6551 account it is
    ///      0x6faff5f1 and `accountData` is `abi.encode(address implementation, bytes32 salt)`;
    ///      `account` then equals the address that the canonical ERC-6551 registry computes
    ///      for this chain, this contract and `tokenId`. Returns the same values after the
    ///      burn, and zero values for a token that was never minted. Does not revert.
    function compositionAccountOf(uint256 tokenId)
        external
        view
        returns (address account, bytes4 accountType, bytes memory accountData);
}
