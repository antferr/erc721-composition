// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721Composition} from "./ERC721Composition.sol";
import {ERC721CompositionMint} from "./ERC721CompositionMint.sol";
import {IERC6551Registry} from "./interfaces/IERC6551.sol";

/// @title Composition token whose containers are ERC-6551 accounts
/// @notice Each token's container is the account that the canonical ERC-6551 registry
///         creates for this chain, this contract and the token id, with a fixed
///         implementation and salt. Only the account address is stored per token; type and
///         verification data are constant for the contract.
contract CompositionToken is ERC721, ERC721Burnable, ERC721CompositionMint {
    IERC6551Registry public constant ERC6551_REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    bytes4 public constant ERC6551_ACCOUNT_INTERFACE_ID = 0x6faff5f1;
    bytes32 public constant ACCOUNT_SALT = bytes32(0);

    address public immutable ACCOUNT_IMPLEMENTATION;

    constructor(address accountImplementation) ERC721("CompositionToken", "CMP") {
        ACCOUNT_IMPLEMENTATION = accountImplementation;
    }

    function _createContainer(uint256 tokenId) internal virtual override returns (address) {
        return
            ERC6551_REGISTRY.createAccount(ACCOUNT_IMPLEMENTATION, ACCOUNT_SALT, block.chainid, address(this), tokenId);
    }

    function _accountTypeAndData(uint256) internal view virtual override returns (bytes4, bytes memory) {
        return (ERC6551_ACCOUNT_INTERFACE_ID, abi.encode(ACCOUNT_IMPLEMENTATION, ACCOUNT_SALT));
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override(ERC721, ERC721Composition)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC721Composition)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
