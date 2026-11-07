// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721Consecutive} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Consecutive.sol";
import {ERC721Composition} from "./ERC721Composition.sol";
import {IERC6551Registry} from "./interfaces/IERC6551.sol";

/// @title Composition token minted in batch during construction (test case)
/// @notice ERC-721 lets a contract create tokens during construction without a `Transfer`
///         event for each one; OpenZeppelin's batch mint emits a single ERC-2309
///         `ConsecutiveTransfer` instead. The composition event must still arrive once per id,
///         every container must be a funded contract before the batch is minted, and the
///         receiver of the batch must not be one of the declared containers.
contract ConsecutiveCompositionToken is ERC721, ERC721Consecutive, ERC721Burnable, ERC721Composition {
    IERC6551Registry public constant ERC6551_REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    bytes4 public constant ERC6551_ACCOUNT_INTERFACE_ID = 0x6faff5f1;
    bytes32 public constant ACCOUNT_SALT = bytes32(0);
    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ACCOUNT_IMPLEMENTATION;

    error NativeAmountMismatch(uint256 expected, uint256 sent);
    error NativeTransferFailed();

    /// @param receiver        Owner of the whole batch.
    /// @param batchSize       Number of tokens, with ids from 0.
    /// @param nativePerToken  Native amount fused into each token; `msg.value` must cover the batch.
    constructor(address accountImplementation, address receiver, uint96 batchSize, uint256 nativePerToken)
        payable
        ERC721("ConsecutiveCompositionToken", "CCT")
    {
        ACCOUNT_IMPLEMENTATION = accountImplementation;
        if (msg.value != nativePerToken * batchSize) {
            revert NativeAmountMismatch(nativePerToken * batchSize, msg.value);
        }

        // containers are created, declared and funded before the batch exists, as for any mint
        uint256 first = _firstConsecutiveId();
        Constituent[] memory constituents = new Constituent[](1);
        constituents[0] = Constituent(NATIVE_ASSET, nativePerToken);

        for (uint256 i; i < batchSize; ++i) {
            uint256 tokenId = first + i;
            address account = ERC6551_REGISTRY.createAccount(
                accountImplementation, ACCOUNT_SALT, block.chainid, address(this), tokenId
            );
            _declareComposition(tokenId, account, constituents);
            (bool ok,) = account.call{value: nativePerToken}("");
            if (!ok) revert NativeTransferFailed();
        }

        // the batch bypasses {_update}: the receiver is checked here, against every container
        (bool declared, uint256 containerTokenId) = _containerToken(receiver);
        if (declared) revert TransferToDeclaredContainer(first, containerTokenId);
        _mintConsecutive(receiver, batchSize);
    }

    function _accountTypeAndData(uint256) internal view override returns (bytes4, bytes memory) {
        return (ERC6551_ACCOUNT_INTERFACE_ID, abi.encode(ACCOUNT_IMPLEMENTATION, ACCOUNT_SALT));
    }

    function _ownerOf(uint256 tokenId) internal view override(ERC721, ERC721Consecutive) returns (address) {
        return super._ownerOf(tokenId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Consecutive, ERC721Composition)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Composition) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
