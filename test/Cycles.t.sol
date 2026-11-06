// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC6551Registry, IERC6551Executable} from "../src/interfaces/IERC6551.sol";
import {ExampleERC6551Account} from "./mocks/Accounts.sol";
import {PlainERC721} from "./mocks/Misc.sol";
import {Variant6551} from "./utils/Variant.sol";
import {CompositionChecks} from "./spec/Checks.sol";

/// @dev C19 and C20: the cycles that the rule on declared containers does not cover. They are
///      shown as a limit for the Security Considerations, not prevented: the token contract
///      cannot see other accounts of the same tokens, nor other collections.
contract CyclesTest is CompositionChecks, Variant6551 {
    ExampleERC6551Account internal ordinary;

    function setUp() public override {
        super.setUp();
        ordinary = new ExampleERC6551Account();
    }

    function _ordinaryAccount(address tokenContract, uint256 tokenId) internal returns (address) {
        return
            IERC6551Registry(REGISTRY)
                .createAccount(address(ordinary), bytes32(0), block.chainid, tokenContract, tokenId);
    }

    /// C19. A goes into an ordinary ERC-6551 account of B, B into an ordinary account of A.
    function test_Cycle_ThroughOtherAccounts_NotPrevented() public {
        uint256 a = _mintThree(alice);
        uint256 b = _mintThree(alice);
        address accountOfA = _ordinaryAccount(address(token), a);
        address accountOfB = _ordinaryAccount(address(token), b);

        vm.startPrank(alice);
        token.transferFrom(alice, accountOfB, a);
        token.transferFrom(alice, accountOfA, b);
        vm.stopPrank();
        assertEq(token.ownerOf(a), accountOfB, "accepted: not a declared container");
        assertEq(token.ownerOf(b), accountOfA, "accepted: not a declared container");

        // each account obeys the owner of the other piece, which is the other account: nobody
        // outside the loop can act, so neither piece can be burned and both containers stay shut
        vm.prank(alice);
        vm.expectRevert();
        token.burn(a);
        vm.prank(alice);
        vm.expectRevert();
        IERC6551Executable(payable(accountOfB)).execute(alice, 0, "", 0);
        vm.prank(alice);
        vm.expectRevert();
        IERC6551Executable(payable(accountOfA)).execute(alice, 0, "", 0);
        assertFalse(_tryExit(alice, _containerOf(a), NATIVE, alice, 1 ether));
        assertFalse(_tryExit(alice, _containerOf(b), NATIVE, alice, 1 ether));
    }

    /// C20. An NFT of another collection sits in A's container, and A in that NFT's account.
    function test_Cycle_ThroughAnotherCollection_NotPrevented() public {
        PlainERC721 other = new PlainERC721();
        other.mint(alice, 7);
        uint256 a = _mintThree(alice);
        address containerOfA = _containerOf(a);
        address accountOfN = _ordinaryAccount(address(other), 7);

        vm.prank(alice);
        other.transferFrom(alice, containerOfA, 7);
        vm.prank(alice);
        token.transferFrom(alice, accountOfN, a);
        assertEq(other.ownerOf(7), containerOfA, "the other collection cannot know our containers");
        assertEq(token.ownerOf(a), accountOfN, "accepted: not a declared container");

        // the account of N obeys the owner of N, A's container, which opens only after A's burn,
        // which needs the owner of A, the account of N
        vm.prank(alice);
        vm.expectRevert();
        token.burn(a);
        vm.prank(alice);
        vm.expectRevert();
        IERC6551Executable(payable(accountOfN)).execute(alice, 0, "", 0);
        assertEq(token.burnedBy(a), address(0));
        assertFalse(_tryExit(alice, containerOfA, NATIVE, alice, 1 ether));
    }
}
