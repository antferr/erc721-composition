// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721Composition} from "../src/IERC721Composition.sol";
import {CompositionToken} from "../src/CompositionToken.sol";
import {CustomContainerCompositionToken} from "../src/CustomContainerCompositionToken.sol";
import {LockedContainer} from "../src/LockedContainer.sol";
import {CompositionReader} from "../src/examples/CompositionReader.sol";
import {IERC6551Account, IERC6551Executable, IERC6551Registry} from "../src/interfaces/IERC6551.sol";
import {ExampleERC6551Account, UpgradeableAccountProxy} from "./mocks/Accounts.sol";
import {PlainERC721, HostileCompositionContract} from "./mocks/Misc.sol";
import {RebasingDownERC20, IssuerControlledERC20} from "./mocks/Tokens.sol";
import {BackdooredCompositionToken, ForeignContainerToken, ForeignCustomContainerToken} from "./mocks/Defects.sol";
import {Intermediary} from "./mocks/Holders.sol";
import {Variant, Variant6551, VariantCustom, ICompositionToken} from "./utils/Variant.sol";
import {CompositionChecks} from "./spec/Checks.sol";
import {Base} from "./Base.t.sol";

/// @dev Builds readers that recognize a given set of code.
abstract contract ReaderFactory is Base {
    uint256 internal constant CALL_GAS = 200_000;
    uint256 internal constant MAX_RETURN_BYTES = 4_096;

    function _reader(address[] memory tokens, address[] memory implementations) internal returns (CompositionReader) {
        bytes32[] memory tokenCodes = new bytes32[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            tokenCodes[i] = tokens[i].codehash;
        }
        bytes32[] memory containerCodes = new bytes32[](1);
        containerCodes[0] = keccak256(type(LockedContainer).runtimeCode);
        return new CompositionReader(tokenCodes, implementations, containerCodes, CALL_GAS, MAX_RETURN_BYTES);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _mintOn(address collection, IERC721Composition.Constituent[] memory c) internal returns (uint256 tokenId) {
        vm.startPrank(alice);
        tokenX.approve(collection, type(uint256).max);
        tokenY.approve(collection, type(uint256).max);
        tokenId = ICompositionToken(collection).mint{value: _nativeOf(c)}(alice, c);
        vm.stopPrank();
    }

    function _accountOf(address collection, uint256 tokenId) internal view returns (address account) {
        (account,,) = IERC721Composition(collection).compositionAccountOf(tokenId);
    }
}

/// @dev E1-E5, E7 and E8: the reader against collections it does not know.
contract ReaderTest is ReaderFactory {
    /// E1 · I3
    function test_Reader_VerifiesBothContainerTypes() public {
        CompositionToken accounts = new CompositionToken(address(implementation));
        CustomContainerCompositionToken custom = new CustomContainerCompositionToken();
        uint256 a = _mintOn(address(accounts), _three(1 ether, 10e18, 20e18));
        uint256 c = _mintOn(address(custom), _three(1 ether, 10e18, 20e18));
        CompositionReader reader = _reader(_list(address(accounts), address(custom)), _list(address(implementation)));

        assertEq(uint8(reader.verify(address(accounts), a)), uint8(CompositionReader.Verdict.Verified));
        assertEq(uint8(reader.verify(address(custom), c)), uint8(CompositionReader.Verdict.Verified));
        (
            CompositionReader.Verdict verdict,
            IERC721Composition.Constituent[] memory constituents,
            uint256[] memory balances,
            bool atLeastDeclared
        ) = reader.inspect(address(accounts), a);
        assertEq(uint8(verdict), uint8(CompositionReader.Verdict.Verified));
        assertTrue(atLeastDeclared);
        for (uint256 i; i < constituents.length; ++i) {
            assertEq(balances[i], constituents[i].amount);
        }
    }

    /// E2 · I1, P8
    function test_Reader_NotSupportedAndNotDeclared() public {
        CompositionToken accounts = new CompositionToken(address(implementation));
        PlainERC721 plain = new PlainERC721();
        plain.mint(alice, 1);
        CompositionReader reader = _reader(_list(address(accounts)), _list(address(implementation)));
        assertEq(uint8(reader.verify(address(plain), 1)), uint8(CompositionReader.Verdict.NotSupported));
        assertEq(uint8(reader.verify(address(accounts), 42)), uint8(CompositionReader.Verdict.NotDeclared));
    }

    /// E3 · P1
    function test_Reader_RejectsWithdrawableAccount() public {
        ExampleERC6551Account ordinary = new ExampleERC6551Account();
        CompositionToken withdrawable = new CompositionToken(address(ordinary));
        uint256 tokenId = _mintOn(address(withdrawable), _three(1 ether, 10e18, 20e18));
        CompositionReader reader = _reader(_list(address(withdrawable)), _list(address(implementation)));
        assertEq(
            uint8(reader.verify(address(withdrawable), tokenId)),
            uint8(CompositionReader.Verdict.UnrecognizedContainerCode)
        );

        // why: the holder empties it while the token exists
        address account = _accountOf(address(withdrawable), tokenId);
        vm.prank(alice);
        IERC6551Executable(payable(account)).execute(alice, 1 ether, "", 0);
        assertEq(account.balance, 0);
        assertEq(withdrawable.ownerOf(tokenId), alice);
    }

    /// E4 · P11
    function test_Reader_RejectsUpgradeableProxyAccount() public {
        address admin = makeAddr("administrator");
        UpgradeableAccountProxy upgradeable = new UpgradeableAccountProxy(admin, address(implementation));
        CompositionToken collection = new CompositionToken(address(upgradeable));
        uint256 tokenId = _mintOn(address(collection), _three(1 ether, 10e18, 20e18));
        address account = _accountOf(address(collection), tokenId);

        CompositionReader reader = _reader(_list(address(collection)), _list(address(implementation)));
        CompositionReader naive = _reader(_list(address(collection)), _list(address(upgradeable)));
        assertEq(
            uint8(reader.verify(address(collection), tokenId)),
            uint8(CompositionReader.Verdict.UnrecognizedContainerCode),
            "rejected from the start"
        );
        assertEq(uint8(naive.verify(address(collection), tokenId)), uint8(CompositionReader.Verdict.Verified));

        // before the upgrade it behaves exactly like the locked account
        assertEq(IERC6551Account(payable(account)).isValidSigner(alice, ""), bytes4(0));
        vm.prank(alice);
        vm.expectRevert();
        IERC6551Executable(payable(account)).execute(alice, 1 ether, "", 0);

        bytes32 codeBefore = account.codehash;
        (, bytes4 typeBefore, bytes memory dataBefore) = collection.compositionAccountOf(tokenId);

        // created before the prank: a creation inside the call's arguments would consume it
        address withdrawableLogic = address(new ExampleERC6551Account());
        vm.prank(admin);
        UpgradeableAccountProxy(payable(account)).upgradeTo(withdrawableLogic);

        // same address, same code at the address, same declared data: nothing on chain shows it
        assertEq(account.codehash, codeBefore);
        (address accountAfter, bytes4 typeAfter, bytes memory dataAfter) = collection.compositionAccountOf(tokenId);
        assertEq(accountAfter, account);
        assertEq(typeAfter, typeBefore);
        assertEq(dataAfter, dataBefore);
        assertEq(uint8(naive.verify(address(collection), tokenId)), uint8(CompositionReader.Verdict.Verified));

        // and yet the holder now empties it while the token exists
        vm.prank(alice);
        IERC6551Executable(payable(account)).execute(alice, 1 ether, "", 0);
        assertEq(account.balance, 0);
        assertEq(collection.ownerOf(tokenId), alice);
        (,,, bool atLeastDeclared) = naive.inspect(address(collection), tokenId);
        assertFalse(atLeastDeclared);
    }

    /// E5 · P1, BR4
    function test_Reader_RejectsUnreviewedTokenContract() public {
        CompositionToken reviewed = new CompositionToken(address(implementation));
        BackdooredCompositionToken backdoored = new BackdooredCompositionToken(address(implementation), bob);
        uint256 tokenId = _mintOn(address(backdoored), _three(1 ether, 10e18, 20e18));
        CompositionReader reader = _reader(_list(address(reviewed)), _list(address(implementation)));
        assertEq(
            uint8(reader.verify(address(backdoored), tokenId)),
            uint8(CompositionReader.Verdict.UnrecognizedTokenContract)
        );

        // why: a perfectly regular locked account obeys the lying burnedBy before the burn
        address account = _accountOf(address(backdoored), tokenId);
        assertEq(IERC6551Account(payable(account)).isValidSigner(bob, ""), ERC6551_SIGNER_MAGIC);
        vm.prank(bob);
        IERC6551Executable(payable(account)).execute(bob, 1 ether, "", 0);
        assertEq(account.balance, 0);
        assertEq(backdoored.ownerOf(tokenId), alice);
    }

    /// E7 · P9, FT4
    function test_Reader_FlagsBalanceBelowDeclared() public {
        CompositionToken collection = new CompositionToken(address(implementation));
        CompositionReader reader = _reader(_list(address(collection)), _list(address(implementation)));
        RebasingDownERC20 rebasing = new RebasingDownERC20();
        rebasing.mint(alice, 100e18);
        vm.prank(alice);
        rebasing.approve(address(collection), type(uint256).max);
        uint256 tokenId = _mintOn(address(collection), _two(address(rebasing), 10e18, NATIVE, 1 ether));
        (,,, bool atLeastDeclared) = reader.inspect(address(collection), tokenId);
        assertTrue(atLeastDeclared);

        rebasing.rebaseDown(0.7e18);
        (
            CompositionReader.Verdict verdict,
            IERC721Composition.Constituent[] memory c,
            uint256[] memory balances,
            bool stillAtLeast
        ) = reader.inspect(address(collection), tokenId);
        assertEq(uint8(verdict), uint8(CompositionReader.Verdict.Verified), "the container is fine");
        assertFalse(stillAtLeast, "the balance is not");
        for (uint256 i; i < c.length; ++i) {
            if (c[i].asset == address(rebasing)) assertEq(balances[i], 7e18);
        }

        IssuerControlledERC20 controlled = new IssuerControlledERC20();
        controlled.mint(alice, 100e18);
        vm.prank(alice);
        controlled.approve(address(collection), type(uint256).max);
        uint256 seized = _mintOn(address(collection), _one(address(controlled), 10e18));
        controlled.seize(_accountOf(address(collection), seized), 1e18);
        (,,, atLeastDeclared) = reader.inspect(address(collection), seized);
        assertFalse(atLeastDeclared);
    }

    /// E8 · I1. The ERC-165 identifier says nothing about the shape of the answers.
    function test_Reader_SurvivesHostileContracts() public {
        CompositionToken collection = new CompositionToken(address(implementation));
        CompositionReader reader = _reader(_list(address(collection)), _list(address(implementation)));
        for (uint8 mode; mode < 4; ++mode) {
            HostileCompositionContract hostile = new HostileCompositionContract(HostileCompositionContract.Mode(mode));
            CompositionReader.Answer memory answer = reader.read{gas: 3_000_000}(address(hostile), 1);
            assertFalse(answer.supported);
            assertEq(answer.constituents.length, 0);
            assertEq(
                uint8(reader.verify{gas: 3_000_000}(address(hostile), 1)), uint8(CompositionReader.Verdict.NotSupported)
            );
        }
    }
}

/// @dev E6, E9 and E10, written once and run on both container types.
abstract contract ReaderVariantSpec is CompositionChecks, ReaderFactory {
    function _deployForeign(address foreignToken, uint256 foreignId) internal virtual returns (address);

    function setUp() public virtual override(Base, Variant) {
        Variant.setUp();
    }

    /// E6 · P3, I3
    function test_Reader_RejectsForeignContainer() public {
        uint256 foreignId = _mintThree(alice);
        address foreign = _deployForeign(address(token), foreignId);
        uint256 tokenId = _mintOn(foreign, _three(1 ether, 10e18, 20e18));
        assertEq(_accountOf(foreign, tokenId), _containerOf(foreignId), "it names someone else's container");
        // even with its code recognized, the binding does not match
        CompositionReader reader = _reader(_list(foreign, address(token)), _list(address(implementation)));
        assertEq(uint8(reader.verify(foreign, tokenId)), uint8(CompositionReader.Verdict.ContainerMismatch));
        assertEq(uint8(reader.verify(address(token), foreignId)), uint8(CompositionReader.Verdict.Verified));
    }

    /// E9 · BR5, BR7, P7
    function test_Container_ActsAsIndependentCustodian() public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        vm.prank(alice);
        token.burn(tokenId);

        vm.roll(vm.getBlockNumber() + 10);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(token.burnedBy(tokenId), alice);
        assertTrue(_tryExit(alice, account, NATIVE, alice, 0.4 ether), "a first part");

        vm.roll(vm.getBlockNumber() + 1_000);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(token.burnedBy(tokenId), alice, "read again at each request, same answer");
        assertTrue(_tryExit(alice, account, NATIVE, alice, 0.6 ether), "the rest, later");
        assertTrue(_tryExit(alice, account, address(tokenX), alice, 10e18));
        assertTrue(_tryExit(alice, account, address(tokenY), alice, 20e18));
        assertEq(account.balance, 0);
    }

    /// E10 · BR2
    function test_IntermediaryBurner_ContentStuck() public {
        Intermediary intermediary = new Intermediary();
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        vm.prank(alice);
        token.safeTransferFrom(alice, address(intermediary), tokenId);
        intermediary.burn(address(token), tokenId);
        assertEq(token.burnedBy(tokenId), address(intermediary));

        address[3] memory others = [alice, bob, stranger];
        for (uint256 i; i < others.length; ++i) {
            assertFalse(_tryExit(others[i], account, NATIVE, others[i], 1 ether));
        }
        // the only one the container obeys has no way to call it
        (bool ok,) = address(intermediary)
            .call(abi.encodeWithSignature("call(address,uint256,bytes)", account, uint256(0), bytes("")));
        assertFalse(ok);
        assertEq(account.balance, 1 ether, "the content stays where it is");
    }
}

contract ReaderERC6551Test is ReaderVariantSpec, Variant6551 {
    function setUp() public override(ReaderVariantSpec, Variant) {
        ReaderVariantSpec.setUp();
    }

    function _deployForeign(address foreignToken, uint256 foreignId) internal override returns (address) {
        return address(new ForeignContainerToken(address(implementation), foreignToken, foreignId));
    }
}

contract ReaderCustomContainerTest is ReaderVariantSpec, VariantCustom {
    function setUp() public override(ReaderVariantSpec, Variant) {
        ReaderVariantSpec.setUp();
    }

    function _deployForeign(address foreignToken, uint256 foreignId) internal override returns (address) {
        return address(new ForeignCustomContainerToken(foreignToken, foreignId));
    }
}
