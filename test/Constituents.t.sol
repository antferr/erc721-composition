// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721Composition} from "../src/IERC721Composition.sol";
import {ERC721CompositionMint} from "../src/ERC721CompositionMint.sol";
import {IERC6551Registry} from "../src/interfaces/IERC6551.sol";
import {FeeOnTransferERC20, RebasingDownERC20, IssuerControlledERC20, HostileERC20} from "./mocks/Tokens.sol";
import {Variant6551} from "./utils/Variant.sol";
import {CompositionChecks} from "./spec/Checks.sol";

/// @dev Group D: constituents and minting. Basis of the Security Considerations on
///      constituents and of the SHOULD NOT in rule 9.
contract ConstituentsTest is CompositionChecks, Variant6551 {
    /// D1 · P5
    function test_FeeOnTransfer_DeclaredNeverAboveReceived() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(alice, 100e18);
        vm.prank(alice);
        fee.approve(address(token), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC721CompositionMint.InsufficientReceived.selector, address(fee), 10e18, 9.9e18)
        );
        token.mint(alice, _one(address(fee), 10e18));
        assertTrue(_checkFeeTokenNeverOverDeclared());
    }

    /// D2 · P9, FT4
    function test_RebasingDown_LowerBoundBreaksWithoutContainerFault() public {
        RebasingDownERC20 rebasing = new RebasingDownERC20();
        rebasing.mint(alice, 100e18);
        vm.prank(alice);
        rebasing.approve(address(token), type(uint256).max);
        uint256 tokenId = _mint(alice, alice, _one(address(rebasing), 10e18));
        address account = _containerOf(tokenId);
        assertTrue(_checkLowerBound(tokenId));

        rebasing.rebaseDown(0.7e18);
        assertEq(rebasing.balanceOf(account), 7e18);
        assertFalse(_checkLowerBound(tokenId), "the lower bound breaks, and the container did nothing");
        assertFalse(_tryExit(alice, account, address(rebasing), alice, 1), "still nothing leaves");

        vm.prank(alice);
        token.burn(tokenId);
        assertTrue(_tryExit(alice, account, address(rebasing), alice, 7e18), "the burner takes what is left");
        assertEq(rebasing.balanceOf(account), 0);
    }

    /// D3 · P9. The burn moves no assets, so a frozen constituent cannot block it.
    function test_IssuerFreezeAndSeize_DoNotBlockTheBurn() public {
        IssuerControlledERC20 controlled = new IssuerControlledERC20();
        controlled.mint(alice, 100e18);
        vm.prank(alice);
        controlled.approve(address(token), type(uint256).max);

        // freeze: the burn still succeeds, because it moves no assets
        uint256 tokenId = _mint(alice, alice, _two(address(controlled), 10e18, NATIVE, 1 ether));
        address account = _containerOf(tokenId);
        controlled.freeze(account, true);
        vm.prank(alice);
        token.burn(tokenId);
        assertEq(token.burnedBy(tokenId), alice);
        assertTrue(_tryExit(alice, account, NATIVE, alice, 1 ether), "the other constituents leave");
        assertFalse(_tryExit(alice, account, address(controlled), alice, 10e18), "the frozen one stays");
        controlled.freeze(account, false);
        assertTrue(_tryExit(alice, account, address(controlled), alice, 10e18), "until the issuer unfreezes it");

        // seize: the balance drops below the declared amount without any action of the container
        uint256 second = _mint(alice, alice, _one(address(controlled), 10e18));
        controlled.seize(_containerOf(second), 4e18);
        assertFalse(_checkLowerBound(second));
    }

    /// D4 · P5
    function test_HostileSurplus_DoesNotBlockDeclared() public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        HostileERC20 hostile = new HostileERC20();
        hostile.mint(account, 1e18);
        vm.prank(alice);
        token.burn(tokenId);
        assertTrue(_tryExit(alice, account, NATIVE, alice, 1 ether));
        assertTrue(_tryExit(alice, account, address(tokenX), alice, 10e18));
        assertTrue(_tryExit(alice, account, address(tokenY), alice, 20e18));
        assertFalse(_tryExit(alice, account, address(hostile), alice, 1e18), "the hostile token stays where it is");
        assertEq(hostile.balanceOf(account), 1e18);
    }

    /// D5 · P5, BR7
    function test_PrefundedAddress_BecomesSurplus() public {
        // the reference mint numbers tokens from 1
        address future = _predictedContainer(address(token), 1);
        vm.startPrank(stranger);
        vm.deal(stranger, 2 ether);
        (bool sent,) = future.call{value: 2 ether}("");
        vm.stopPrank();
        assertTrue(sent);
        vm.prank(bob);
        tokenX.transfer(future, 5e18);

        IERC721Composition.Constituent[] memory declared = _two(address(tokenX), 10e18, NATIVE, 1 ether);
        uint256 tokenId = _mint(alice, alice, declared);
        assertEq(tokenId, 1);
        assertEq(_containerOf(tokenId), future);
        assertEq(abi.encode(token.compositionOf(tokenId)), abi.encode(declared), "what arrived before is not declared");
        assertEq(future.balance, 3 ether);
        assertEq(tokenX.balanceOf(future), 15e18);
        assertFalse(_tryExit(stranger, future, NATIVE, stranger, 2 ether), "not even the one who sent it");

        vm.prank(alice);
        token.burn(tokenId);
        assertTrue(_tryExit(alice, future, NATIVE, alice, 3 ether), "surplus leaves with the rest");
        assertTrue(_tryExit(alice, future, address(tokenX), alice, 15e18));

        // assets sent for an id never minted: even once someone creates the account, nobody can act
        address never = _predictedContainer(address(token), 999);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (sent,) = never.call{value: 1 ether}("");
        assertTrue(sent);
        IERC6551Registry(REGISTRY)
            .createAccount(address(implementation), bytes32(0), block.chainid, address(token), 999);
        assertEq(never.code.length > 0, true);
        assertFalse(_tryExit(stranger, never, NATIVE, stranger, 1 ether));
        assertFalse(_tryExit(alice, never, NATIVE, alice, 1 ether));
    }

    /// D6 · P10, I3
    function test_AccountCreatedInAdvance_MintStillWorks() public {
        vm.prank(stranger);
        address created = IERC6551Registry(REGISTRY)
            .createAccount(address(implementation), bytes32(0), block.chainid, address(token), 1);
        assertGt(created.code.length, 0);
        uint256 tokenId = _mintThree(alice);
        assertEq(tokenId, 1);
        assertEq(_containerOf(tokenId), created, "the registry returns the existing account");
        assertTrue(_checkConformance(tokenId));
        assertTrue(_checkLowerBound(tokenId));
    }
}
