// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721Composition} from "./ERC721Composition.sol";
import {ERC721CompositionMint} from "./ERC721CompositionMint.sol";
import {ILockedContainer, LockedContainer} from "./LockedContainer.sol";

/// @title Composition token whose containers are custom contracts, not ERC-6551 accounts
/// @notice Shows that the interface does not depend on ERC-6551: the container type is the
///         ERC-165 identifier of {ILockedContainer} and no verification data is needed,
///         because a reader recognizes the container by its code hash and reads its binding
///         with `token()`.
contract CustomContainerCompositionToken is ERC721, ERC721Burnable, ERC721CompositionMint {
    constructor() ERC721("CustomContainerCompositionToken", "CCC") {}

    function _createContainer(uint256 tokenId) internal override returns (address) {
        return address(new LockedContainer{salt: bytes32(tokenId)}(address(this), tokenId));
    }

    function _accountTypeAndData(uint256) internal pure override returns (bytes4, bytes memory) {
        return (type(ILockedContainer).interfaceId, "");
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Composition)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Composition) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
