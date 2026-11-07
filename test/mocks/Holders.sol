// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {ILockedContainer} from "../../src/LockedContainer.sol";
import {IERC6551Executable} from "../../src/interfaces/IERC6551.sol";

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

/// @dev A recipient that inspects the token from inside `onERC721Received`, the first moment
///      another contract can see it, and can burn it and empty its container right there.
contract MintCallbackReceiver is IERC721Receiver {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bool public immutable ERC6551;
    bool public burnAndWithdraw;

    bool public called;
    bool public sawOwner;
    bool public sawDeclared;
    bool public sawContract;
    bool public sawBacking;

    constructor(bool erc6551, bool burnAndWithdraw_) {
        ERC6551 = erc6551;
        burnAndWithdraw = burnAndWithdraw_;
    }

    receive() external payable {}

    /// @dev True if, inside the callback, the token was owned, declared, held in a container
    ///      that was already a contract and that already held every declared amount.
    function sawBackedToken() external view returns (bool) {
        return called && sawOwner && sawDeclared && sawContract && sawBacking;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        called = true;
        IERC721Composition token = IERC721Composition(msg.sender);
        sawOwner = IERC721(msg.sender).ownerOf(tokenId) == address(this);
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        (address account,,) = token.compositionAccountOf(tokenId);
        sawDeclared = c.length != 0 && account != address(0);
        sawContract = account.code.length != 0;
        bool backed = sawDeclared;
        for (uint256 i; i < c.length; ++i) {
            if (_balance(c[i].asset, account) < c[i].amount) backed = false;
        }
        sawBacking = backed;

        if (burnAndWithdraw) {
            IBurnable(msg.sender).burn(tokenId);
            for (uint256 i; i < c.length; ++i) {
                _withdrawAll(account, c[i].asset);
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function _balance(address asset, address holder) internal view returns (uint256) {
        return asset == NATIVE ? holder.balance : IERC20(asset).balanceOf(holder);
    }

    function _withdrawAll(address account, address asset) internal {
        uint256 amount = _balance(asset, account);
        if (!ERC6551) {
            ILockedContainer(account).withdraw(asset, address(this), amount);
        } else if (asset == NATIVE) {
            IERC6551Executable(payable(account)).execute(address(this), amount, "", 0);
        } else {
            IERC6551Executable(payable(account))
                .execute(asset, 0, abi.encodeCall(IERC20.transfer, (address(this), amount)), 0);
        }
    }
}
