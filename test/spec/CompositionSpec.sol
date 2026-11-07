// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {ERC721Composition} from "../../src/ERC721Composition.sol";
import {ERC721CompositionMint} from "../../src/ERC721CompositionMint.sol";
import {IERC6551Account, IERC6551Executable} from "../../src/interfaces/IERC6551.sol";
import {Holder, MintCallbackReceiver} from "../mocks/Holders.sol";
import {IForceMint} from "../utils/Variant.sol";
import {CompositionChecks} from "./Checks.sol";

interface IBoundContainer {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
}

/// @dev Groups A, B and C, written once and run on both container types.
///      The comment on each test gives its identifier and the rules it checks (see the README).
abstract contract CompositionSpec is CompositionChecks {
    // ============================================================ group A, semantics

    /// A1 · P9, I2, FT1
    function test_Mint_ReturnsDeclaredComposition() public {
        IERC721Composition.Constituent[] memory declared = _three(1 ether, 10e18, 20e18);
        uint256 tokenId = _mint(alice, alice, declared);
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        assertEq(abi.encode(c), abi.encode(declared), "declared pairs");
        bool native;
        for (uint256 i; i < c.length; ++i) {
            if (i > 0) assertLt(uint160(c[i - 1].asset), uint160(c[i].asset), "strictly increasing");
            if (c[i].asset == NATIVE) native = true;
        }
        assertTrue(native, "native asset at the ERC-7528 address");
        assertTrue(_checkConformance(tokenId));
    }

    /// A2 · I3, FT2
    function test_Mint_ReturnsContainerData() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkContainerData(tokenId), "address, type and data");
        (uint256 chainId, address bound, uint256 boundId) = IBoundContainer(_containerOf(tokenId)).token();
        assertEq(chainId, block.chainid);
        assertEq(bound, address(token));
        assertEq(boundId, tokenId);
    }

    /// A3 · P10
    function test_Container_IsContractAtMintEnd() public {
        assertEq(_predictedContainer(address(token), 1).code.length, 0, "no code before the mint");
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkContainerIsContract(tokenId));
    }

    /// A4 · P5, FT4
    function test_LowerBound_AtMintEnd() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkLowerBound(tokenId));
        assertTrue(_checkConformance(tokenId));
    }

    /// A13 · P5, P10. A contract that receives the token through `onERC721Received` already
    ///     finds it declared, its container a contract and the declared amounts inside: the
    ///     lower bound holds from the moment the token can be seen.
    function test_MintCallback_SeesBackedToken() public {
        assertTrue(_checkBackedWhenReceived());
    }

    /// A14 · P1, P5, P7, BR4. The recipient checks the backing, then burns the token and
    ///     empties the container inside `onERC721Received`. The minting transaction ends below
    ///     the declared amounts: that is release after the burn, not a broken lower bound.
    function test_MintCallback_BurnAndWithdrawDuringMint() public {
        MintCallbackReceiver receiver = new MintCallbackReceiver(_isERC6551(), true);
        IERC721Composition.Constituent[] memory declared = _three(1 ether, 10e18, 20e18);
        uint256 tokenId = _mint(alice, address(receiver), declared);
        address account = _containerOf(tokenId);

        assertTrue(receiver.sawBackedToken(), "backed when first seen");
        assertEq(token.burnedBy(tokenId), address(receiver), "burned by the recipient");
        vm.expectRevert();
        token.ownerOf(tokenId);
        for (uint256 i; i < declared.length; ++i) {
            assertEq(_balance(declared[i].asset, account), 0, "container emptied");
            assertEq(_balance(declared[i].asset, address(receiver)), declared[i].amount, "released to the burner");
        }
        assertEq(abi.encode(token.compositionOf(tokenId)), abi.encode(declared), "declaration unchanged");
        assertTrue(_checkViewsAnswer(tokenId));
    }

    /// A5 · P8, I3
    function test_NeverMinted_ReturnsEmpty() public view {
        assertTrue(_checkNeverMintedIsEmpty(42));
    }

    /// A6 · P8
    function testFuzz_Views_NeverRevert(uint256 tokenId, uint8 state) public {
        state = state % 3;
        if (state == 1) {
            tokenId = _mintThree(alice);
        } else if (state == 2) {
            tokenId = _mintThree(alice);
            vm.prank(alice);
            token.burn(tokenId);
        }
        assertTrue(_checkViewsAnswer(tokenId));
    }

    /// A7 · P4, P8, FT3
    function test_AfterBurn_SameValues() public {
        uint256 tokenId = _mintThree(alice);
        bytes memory before = _encodedDeclaration(tokenId);
        vm.prank(alice);
        token.burn(tokenId);
        assertEq(_encodedDeclaration(tokenId), before);
        assertEq(token.burnedBy(tokenId), alice);
    }

    /// A8 · P4, FT1, FT2
    function test_Lifecycle_ValuesNeverChange() public {
        assertTrue(_checkLifecycleValuesNeverChange());
    }

    /// A9 · P6, I4, FT1, FT2
    function test_Event_OncePerMint_SameData() public {
        assertTrue(_checkMintEventMatchesFunctions());
    }

    /// A11 · P6, FT1-FT4. The expected values written here are the independent
    ///       model: the index rebuilt from the logs alone must match both them and the functions.
    function test_Replay_EventsMatchFunctionsAndExpected() public {
        IERC721Composition.Constituent[][3] memory declared =
            [_three(1 ether, 10e18, 20e18), _one(NATIVE, 2 ether), _two(address(tokenX), 5e18, NATIVE, 3 ether)];
        address[3] memory burners;
        uint256[3] memory ids;

        vm.recordLogs();
        ids[0] = _mint(alice, alice, declared[0]);
        _step(ids, declared, burners);
        ids[1] = _mint(alice, bob, declared[1]);
        _step(ids, declared, burners);
        ids[2] = _mint(bob, carol, declared[2]);
        _step(ids, declared, burners);
        vm.prank(alice);
        token.transferFrom(alice, bob, ids[0]);
        _step(ids, declared, burners);
        vm.prank(bob);
        token.burn(ids[0]);
        burners[0] = bob;
        _step(ids, declared, burners);
        address secondContainer = _containerOf(ids[1]);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = secondContainer.call{value: 1 ether}("");
        assertTrue(sent);
        _step(ids, declared, burners);
        assertEq(_containerOf(ids[1]).balance, 3 ether, "balances come from the chain, not from the logs");
    }

    function _step(
        uint256[3] memory ids,
        IERC721Composition.Constituent[][3] memory declared,
        address[3] memory burners
    ) internal {
        _ingest(address(token), vm.getRecordedLogs());
        vm.recordLogs();
        for (uint256 i; i < 3; ++i) {
            if (ids[i] == 0) continue;
            Indexed storage entry = _index[address(token)][ids[i]];
            assertTrue(_indexAgreesWithFunctions(address(token), ids[i]), "index and functions");
            assertEq(entry.composition, abi.encode(declared[i]), "index and expected composition");
            assertEq(entry.account, _predictedContainer(address(token), ids[i]), "index and expected container");
            assertEq(entry.accountType, _expectedType());
            assertEq(entry.accountData, _expectedData(address(token)));
            assertEq(entry.burner, burners[i], "index and expected burner");
            assertEq(abi.encode(token.compositionOf(ids[i])), abi.encode(declared[i]), "function and expected");
        }
    }

    /// A12 · P9 (reference mint, repository only)
    function test_Mint_RejectsMalformedComposition() public {
        vm.startPrank(alice);
        vm.expectRevert(ERC721Composition.EmptyComposition.selector);
        token.mint(alice, new IERC721Composition.Constituent[](0));

        IERC721Composition.Constituent[] memory unsorted = _three(1 ether, 10e18, 20e18);
        (unsorted[0], unsorted[1]) = (unsorted[1], unsorted[0]);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.UnsortedConstituent.selector, 1));
        token.mint{value: 1 ether}(alice, unsorted);

        IERC721Composition.Constituent[] memory duplicate = new IERC721Composition.Constituent[](2);
        duplicate[0] = IERC721Composition.Constituent(address(tokenX), 1e18);
        duplicate[1] = IERC721Composition.Constituent(address(tokenX), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.UnsortedConstituent.selector, 1));
        token.mint(alice, duplicate);

        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.UnsortedConstituent.selector, 0));
        token.mint(alice, _one(address(0), 1));

        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.ZeroAmountConstituent.selector, 0));
        token.mint(alice, _one(address(tokenX), 0));

        vm.expectRevert(abi.encodeWithSelector(ERC721CompositionMint.NativeAmountMismatch.selector, 1 ether, 2 ether));
        token.mint{value: 2 ether}(alice, _one(NATIVE, 1 ether));
        vm.stopPrank();

        address harness = _deployHarness();
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.CompositionNotDeclared.selector, 99));
        IForceMint(harness).forceMint(bob, 99);
    }

    // ============================================================ group B, detection

    /// B3 · I1
    function test_SupportsInterface() public view {
        assertTrue(token.supportsInterface(COMPOSITION_ID), "composition");
        assertTrue(token.supportsInterface(BURN_RECORD_ID), "ERC-8423");
        assertTrue(token.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(token.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(token.supportsInterface(0xffffffff));
    }

    /// B5 · I3
    function test_Container_PassesErc165Detection() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkContainerPassesErc165(tokenId));
    }

    // ============================================================ group C, lock and cycles

    /// C1 · P1, FT4
    function test_BeforeBurn_NothingLeaves() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkNothingLeavesBeforeBurn(tokenId));
    }

    /// C2 · P1. Random caller, exit, destination, amount, data and operation.
    function testFuzz_BeforeBurn_NoCallMovesAssets(
        uint8 callerSeed,
        uint8 path,
        address to,
        uint256 amount,
        bytes calldata data,
        uint8 operation
    ) public {
        uint256 tokenId = _mintThree(alice);
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        address account = _containerOf(tokenId);
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        uint256[] memory before = _balances(tokenId);
        address[7] memory callers = [alice, bob, carol, address(token), stranger, account, address(uint160(amount))];
        address caller = callers[callerSeed % callers.length];
        address asset = c[amount % c.length].asset;
        amount = bound(amount, 1, 1_000 ether);

        path = path % 4;
        if (path == 0) {
            _tryExit(caller, account, asset, to, amount);
        } else if (path == 1) {
            if (asset != NATIVE) _tryApprove(caller, account, asset, caller);
        } else if (path == 2) {
            vm.prank(caller);
            (bool ok,) = account.call(data);
            ok;
        } else if (_isERC6551()) {
            vm.prank(caller);
            try IERC6551Executable(payable(account)).execute(to, amount, data, operation) {} catch {}
        } else {
            _tryExit(caller, account, asset, to, amount);
        }

        uint256[] memory afterCall = _balances(tokenId);
        for (uint256 i; i < c.length; ++i) {
            assertGe(afterCall[i], before[i], "nothing left the container");
            if (c[i].asset != NATIVE) assertEq(IERC20(c[i].asset).allowance(account, caller), 0, "no allowance");
        }
    }

    /// C6 · P1, P2, P5, BR5
    function test_AfterBurn_OnlyBurnerMovesAssets_IncludingSurplus() public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        vm.prank(bob);
        (bool sent,) = account.call{value: 0.5 ether}("");
        assertTrue(sent, "surplus sent after the mint");

        vm.prank(alice);
        token.burn(tokenId);
        if (_isERC6551()) {
            bytes32 hash = keccak256("an authorization");
            assertEq(IERC6551Account(payable(account)).isValidSigner(alice, ""), ERC6551_SIGNER_MAGIC);
            assertEq(IERC6551Account(payable(account)).isValidSigner(bob, ""), bytes4(0));
            assertEq(IERC6551Account(payable(account)).isValidSigner(address(token), ""), bytes4(0));
            assertEq(_isValidSignature(account, hash, _sign(aliceKey, hash)), ERC1271_MAGIC);
            assertTrue(_isValidSignature(account, hash, _sign(bobKey, hash)) != ERC1271_MAGIC);
        }
        address[4] memory others = [bob, carol, address(token), stranger];
        for (uint256 k; k < others.length; ++k) {
            assertFalse(_tryExit(others[k], account, NATIVE, others[k], 1), "only the burner");
            assertFalse(_tryExit(others[k], account, address(tokenX), others[k], 1), "only the burner");
        }
        uint256 aliceNative = alice.balance;
        assertTrue(_tryExit(alice, account, NATIVE, alice, 1.5 ether), "declared and surplus");
        assertTrue(_tryExit(alice, account, address(tokenX), alice, 10e18));
        assertTrue(_tryExit(alice, account, address(tokenY), alice, 20e18));
        assertEq(alice.balance, aliceNative + 1.5 ether);
        assertEq(account.balance, 0);
        assertEq(tokenX.balanceOf(account), 0);
        assertEq(tokenY.balanceOf(account), 0);
    }

    /// C7 · P1, BR2
    function test_TransferThenBurn_LastOwnerOpens() public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        vm.prank(alice);
        token.transferFrom(alice, bob, tokenId);
        vm.prank(bob);
        token.burn(tokenId);
        assertEq(token.burnedBy(tokenId), bob);
        assertFalse(_tryExit(alice, account, NATIVE, alice, 1 ether), "the previous owner no longer");
        assertTrue(_tryExit(bob, account, NATIVE, bob, 1 ether), "the owner at the burn");
    }

    /// C8 · P1, BR2
    function test_OperatorBurn_ContentStaysWithOwner() public {
        uint256 first = _mintThree(alice);
        uint256 second = _mintThree(alice);
        vm.startPrank(alice);
        token.approve(carol, first);
        token.setApprovalForAll(bob, true);
        vm.stopPrank();

        vm.prank(carol);
        token.burn(first);
        vm.prank(bob);
        token.burn(second);
        assertEq(token.burnedBy(first), alice, "the owner at the burn, not the approved address");
        assertEq(token.burnedBy(second), alice, "the owner at the burn, not the operator");
        assertFalse(_tryExit(carol, _containerOf(first), NATIVE, carol, 1 ether));
        assertFalse(_tryExit(bob, _containerOf(second), NATIVE, bob, 1 ether));
        assertTrue(_tryExit(alice, _containerOf(first), NATIVE, alice, 1 ether));
        assertTrue(_tryExit(alice, _containerOf(second), NATIVE, alice, 1 ether));
    }

    /// C9 · P1, BR2
    function test_HolderContractBurn_OnlyHolderOpens() public {
        Holder h = new Holder();
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        vm.prank(alice);
        token.safeTransferFrom(alice, address(h), tokenId);
        h.burn(address(token), tokenId);
        assertEq(token.burnedBy(tokenId), address(h));
        assertFalse(_tryExit(alice, account, NATIVE, alice, 1 ether), "not the one who sent it to H");
        assertTrue(_tryExit(address(h), account, NATIVE, address(h), 1 ether), "H, the owner at the burn");
    }

    /// C10 · P1
    function test_OtherChain_NothingValidates() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkOtherChainNothingValidates(tokenId));
    }

    /// C11 · P7, BR4
    function test_Remint_Rejected() public {
        assertTrue(_checkRemintRejected(_deployHarness()));
        // the public mint never reuses an id: it always mints the next one
        uint256 tokenId = _mintThree(alice);
        vm.prank(alice);
        token.burn(tokenId);
        assertEq(_mintThree(alice), tokenId + 1);
        assertEq(token.burnedBy(tokenId), alice);
    }

    /// C12 · P3, P12
    function test_TransferOrMintToOwnContainer_Rejected() public {
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkOwnContainerRejected(tokenId));
        // a mint whose recipient is the container that the mint itself creates
        uint256 next = tokenId + 1;
        address nextContainer = _predictedContainer(address(token), next);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, next, next));
        token.mint{value: 1 ether}(nextContainer, _one(NATIVE, 1 ether));
    }

    /// C13 · P12
    function test_TransferOrMintToAnyDeclaredContainer_Rejected() public {
        assertTrue(_checkOtherContainerRejected());
        uint256 a = _mintThree(alice);
        uint256 burned = _mintThree(alice);
        vm.prank(alice);
        token.burn(burned);
        address burnedContainer = _containerOf(burned);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, a, burned));
        token.transferFrom(alice, burnedContainer, a);

        uint256 next = burned + 1;
        address containerOfA = _containerOf(a);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, next, a));
        token.mint{value: 1 ether}(containerOfA, _one(NATIVE, 1 ether));
    }

    /// C15 · P12
    function test_TwoPieceCycle_CannotClose() public {
        assertTrue(_checkTwoPieceCycleCannotClose());
        if (!_isERC6551()) return;
        // the piece sent ahead is not lost: the burner of the later piece can take it out
        uint256 first = _mintThree(alice);
        address ahead = _predictedContainer(address(token), first + 1);
        vm.prank(alice);
        token.transferFrom(alice, ahead, first);
        uint256 second = _mintThree(alice);
        address secondContainer = _containerOf(second);
        assertEq(token.ownerOf(first), secondContainer);
        vm.prank(alice);
        token.burn(second);
        vm.prank(alice);
        IERC6551Executable(payable(secondContainer))
            .execute(address(token), 0, abi.encodeCall(IERC721.transferFrom, (secondContainer, alice, first)), 0);
        assertEq(token.ownerOf(first), alice);
    }

    /// C16 · P12
    function test_ChainOfThree_NeverCloses() public {
        assertTrue(_checkChainOfThreeNeverCloses());
    }

    /// C17 · P3 (batch part in Batch.t.sol)
    function test_Containers_AreDistinct() public {
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _mintThree(alice);
        }
        assertTrue(_checkContainersDistinct(ids));
    }

    /// C18 · P11
    function test_Implementation_NoDelegationNoSelfdestruct() public {
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        address code = _isERC6551() ? address(implementation) : account;
        (bool delegatecall, bool callcode, bool selfdestruct_) = _scanOpcodes(code.code);
        assertFalse(delegatecall, "no DELEGATECALL");
        assertFalse(callcode, "no CALLCODE");
        assertFalse(selfdestruct_, "no SELFDESTRUCT");
        if (_isERC6551()) {
            (delegatecall,,) = _scanOpcodes(account.code);
            assertTrue(delegatecall, "the registry's proxy delegates to the implementation, by design");
        }
    }

    // ------------------------------------------------------------ helpers

    function _isValidSignature(address account, bytes32 hash, bytes memory signature) internal view returns (bytes4) {
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", hash, signature));
        if (!ok || ret.length != 32) return bytes4(0);
        return abi.decode(ret, (bytes4));
    }

    /// @dev Walks the code as the EVM would, skipping the data of PUSH instructions and the
    ///      metadata that the compiler appends, whose length is in the last two bytes.
    function _scanOpcodes(bytes memory code)
        internal
        pure
        returns (bool delegatecall, bool callcode, bool selfdestruct_)
    {
        uint256 end = code.length;
        if (end >= 2) {
            uint256 metadata = (uint256(uint8(code[end - 2])) << 8) | uint256(uint8(code[end - 1]));
            if (metadata + 2 <= end) end -= metadata + 2;
        }
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf4) delegatecall = true;
            else if (op == 0xf2) callcode = true;
            else if (op == 0xff) selfdestruct_ = true;
            else if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
    }
}
