// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IBurnable {
    function burn(uint256 tokenId) external;
}

/// @dev `H` in the tests: a contract that holds tokens, burns them and can operate on a
///      container through arbitrary calls, as a smart account would.
contract Holder is IERC721Receiver {
    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function burn(address token, uint256 tokenId) external {
        IBurnable(token).burn(tokenId);
    }

    function call(address target, uint256 value, bytes calldata data) external payable returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @dev A contract that holds and burns tokens, like a router or a marketplace, but has no way
///      to call a container: whatever it burns stays locked for good.
contract Intermediary is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function burn(address token, uint256 tokenId) external {
        IBurnable(token).burn(tokenId);
    }
}
