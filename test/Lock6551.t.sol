// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC6551Account} from "../src/interfaces/IERC6551.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureTransferERC20} from "./mocks/Tokens.sol";
import {Variant6551} from "./utils/Variant.sol";
import {CompositionChecks} from "./spec/Checks.sol";

/// @dev C3, C4 and C5: the two calls that ERC-6551 accounts must spell out (P2), and the
///      ERC-1271 path that an account locking only `execute` would leave open.
contract Lock6551Test is CompositionChecks, Variant6551 {
    /// C3 · P2
    function test_Erc6551_NoValidSignerOrSignatureBeforeBurn() public {
        uint256 tokenId = _mintThree(alice);
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        vm.prank(alice);
        token.approve(carol, tokenId);
        assertTrue(_checkNoSignerOrSignatureBeforeBurn(tokenId));
    }

    /// C4 · P2
    function testFuzz_Erc6551_NoMagicValueBeforeBurn(
        address signer,
        bytes calldata context,
        bytes32 hash,
        bytes calldata signature,
        uint256 key
    ) public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        assertTrue(IERC6551Account(payable(account)).isValidSigner(signer, context) != ERC6551_SIGNER_MAGIC);
        assertTrue(IERC1271(account).isValidSignature(hash, signature) != ERC1271_MAGIC);
        key = bound(key, 1, 1e70);
        assertTrue(IERC1271(account).isValidSignature(hash, _sign(key, hash)) != ERC1271_MAGIC);
        assertTrue(IERC1271(account).isValidSignature(hash, _sign(aliceKey, hash)) != ERC1271_MAGIC);
    }

    /// C5 · P1, P2
    function test_Erc1271Consumer_RejectsSignedTransferBeforeBurn() public {
        assertTrue(_checkErc1271ConsumerBeforeBurn(), "refused before the burn");

        // after the burn the burner's authorization is accepted, Bob's is not
        SignatureTransferERC20 sig = new SignatureTransferERC20();
        sig.mint(alice, 100e18);
        vm.prank(alice);
        sig.approve(address(token), type(uint256).max);
        uint256 tokenId = _mint(alice, alice, _one(address(sig), 10e18));
        address account = _containerOf(tokenId);
        vm.prank(alice);
        token.burn(tokenId);

        bytes memory byBob = _sign(bobKey, sig.authorizationDigest(account, bob, 10e18, 1));
        vm.expectRevert(SignatureTransferERC20.InvalidAuthorization.selector);
        sig.transferWithSignature(account, bob, 10e18, 1, byBob);

        bytes memory byAlice = _sign(aliceKey, sig.authorizationDigest(account, alice, 10e18, 1));
        sig.transferWithSignature(account, alice, 10e18, 1, byAlice);
        assertEq(sig.balanceOf(account), 0);
        assertEq(sig.balanceOf(alice), 100e18);
    }
}
