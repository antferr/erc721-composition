// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721BurnRecord} from "erc721-burn-record/ERC721BurnRecord.sol";
import {IERC721Composition} from "./IERC721Composition.sol";

/// @title Reference implementation of the ERC-721 composition extension
/// @notice Keeps the declared composition and the container of each token in state. The state
///         is the source of truth, the two functions read it, and {CompositionDeclared}
///         announces it once per token.
/// @dev Rules enforced here, on top of ERC-721 and ERC-8423:
///      - every token is minted with a declaration: at least one constituent, assets in
///        strictly increasing address order, no zero amount, and a container that is already a
///        contract and is declared for no other token;
///      - composition and container never change, not even after the burn;
///      - a burned token id is never minted again, so the burner recorded by ERC-8423 never
///        changes;
///      - no token of this contract is ever transferred or minted to a container this contract
///        has declared: its own, another token's, live or burned. Inside the collection this
///        rules out every ownership cycle through the declared containers.
///      Minting stays with the inheriting contract, which MUST call {_declareComposition} for
///      every token it creates, in the same transaction and before any untrusted external call.
///      Tokens minted through {_update} are rejected unless declared. Tokens minted in batch
///      during construction (ERC-721 Consecutive) bypass {_update}: the inheriting contract
///      declares them one by one and checks the receiver with {_containerToken}.
abstract contract ERC721Composition is ERC721BurnRecord, IERC721Composition {
    /// @dev Container and number of constituents of a declared token, packed in one slot.
    struct Declaration {
        address account;
        uint96 length;
    }

    mapping(uint256 tokenId => Declaration) private _declarations;
    mapping(uint256 tokenId => mapping(uint256 index => Constituent)) private _constituents;
    /// @dev Reverse index of the declared containers: token id plus one, zero if not declared.
    mapping(address account => uint256 tokenIdPlusOne) private _containerTokens;

    error CompositionAlreadyDeclared(uint256 tokenId);
    error CompositionNotDeclared(uint256 tokenId);
    error EmptyComposition();
    error UnsortedConstituent(uint256 index);
    error ZeroAmountConstituent(uint256 index);
    error InvalidAccount(address account);
    error ContainerAlreadyDeclared(address account, uint256 containerTokenId);
    error TransferToDeclaredContainer(uint256 tokenId, uint256 containerTokenId);
    error BurnedTokenRemint(uint256 tokenId);

    /// @inheritdoc IERC721Composition
    function compositionOf(uint256 tokenId) public view virtual returns (Constituent[] memory constituents) {
        uint256 length = _declarations[tokenId].length;
        constituents = new Constituent[](length);
        mapping(uint256 => Constituent) storage stored = _constituents[tokenId];
        for (uint256 i; i < length; ++i) {
            constituents[i] = stored[i];
        }
    }

    /// @inheritdoc IERC721Composition
    function compositionAccountOf(uint256 tokenId)
        public
        view
        virtual
        returns (address account, bytes4 accountType, bytes memory accountData)
    {
        account = _declarations[tokenId].account;
        if (account != address(0)) {
            (accountType, accountData) = _accountTypeAndData(tokenId);
        }
    }

    /// @dev See {IERC165-supportsInterface}. Also reports ERC-8423 through {ERC721BurnRecord}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC721Composition).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Type and verification data of the container of a declared token. Constant for
    ///      each token: implementations derive them from immutable parameters.
    function _accountTypeAndData(uint256 tokenId) internal view virtual returns (bytes4, bytes memory);

    /// @dev Whether `account` is a container this contract has declared, and for which token.
    function _containerToken(address account) internal view returns (bool declared, uint256 tokenId) {
        uint256 tokenIdPlusOne = _containerTokens[account];
        declared = tokenIdPlusOne != 0;
        if (declared) tokenId = tokenIdPlusOne - 1;
    }

    /// @dev Records the composition and the container of `tokenId` and emits
    ///      {CompositionDeclared}. Checks that the container is a deployed contract declared
    ///      for no other token, and that the constituents are non-empty, sorted by strictly
    ///      increasing asset address (so neither duplicates nor the zero address can appear)
    ///      and with non-zero amounts. The caller ensures that the container holds at least
    ///      the declared amounts by the end of the minting transaction.
    function _declareComposition(uint256 tokenId, address account, Constituent[] memory constituents) internal virtual {
        if (_declarations[tokenId].account != address(0)) revert CompositionAlreadyDeclared(tokenId);
        if (account == address(0) || account.code.length == 0) revert InvalidAccount(account);
        uint256 holder = _containerTokens[account];
        if (holder != 0) revert ContainerAlreadyDeclared(account, holder - 1);
        uint256 length = constituents.length;
        if (length == 0) revert EmptyComposition();

        mapping(uint256 => Constituent) storage stored = _constituents[tokenId];
        // starting from zero, the first asset must be above the zero address
        address previous = address(0);
        for (uint256 i; i < length; ++i) {
            Constituent memory constituent = constituents[i];
            if (constituent.asset <= previous) revert UnsortedConstituent(i);
            if (constituent.amount == 0) revert ZeroAmountConstituent(i);
            stored[i] = constituent;
            previous = constituent.asset;
        }
        // a memory array cannot come anywhere near 2^96 elements within a block's gas limit
        // forge-lint: disable-next-line(unsafe-typecast)
        _declarations[tokenId] = Declaration(account, uint96(length));
        _containerTokens[account] = tokenId + 1;

        (bytes4 accountType, bytes memory accountData) = _accountTypeAndData(tokenId);
        emit CompositionDeclared(tokenId, account, accountType, accountData, constituents);
    }

    /// @dev Rejects a transfer or a mint to any declared container, a mint of an undeclared
    ///      token and a mint of a burned token.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        if (to != address(0)) {
            uint256 holder = _containerTokens[to];
            if (holder != 0) revert TransferToDeclaredContainer(tokenId, holder - 1);
            if (_ownerOf(tokenId) == address(0)) {
                if (_declarations[tokenId].account == address(0)) revert CompositionNotDeclared(tokenId);
                if (burnedBy(tokenId) != address(0)) revert BurnedTokenRemint(tokenId);
            }
        }
        return super._update(to, tokenId, auth);
    }
}
