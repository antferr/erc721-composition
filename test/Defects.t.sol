// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Composition} from "../src/IERC721Composition.sol";
import {CompositionToken} from "../src/CompositionToken.sol";
import {ConsecutiveCompositionToken} from "../src/ConsecutiveCompositionToken.sol";
import {LockedContainer} from "../src/LockedContainer.sol";
import {CompositionReader} from "../src/examples/CompositionReader.sol";
import {LeakySignatureAccount, ChainBlindAccount} from "./mocks/Accounts.sol";
import {FeeOnTransferERC20, SignatureTransferERC20} from "./mocks/Tokens.sol";
import {
    CompositionTokenHarness,
    RemintableCompositionToken,
    MutableCompositionToken,
    MismatchedEventToken,
    ConsistentlyWrongToken,
    SilentBatchToken,
    RevertingViewToken,
    NoOwnContainerCheckToken,
    OwnContainerOnlyToken,
    SharedContainerToken,
    LazyContainerToken,
    UnmeasuredMintToken,
    MintBeforeFundToken
} from "./mocks/Defects.sol";
import {Variant, Variant6551} from "./utils/Variant.sol";
import {CompositionChecks} from "./spec/Checks.sol";
import {Handler6551} from "./invariant/CompositionHandler.sol";
import {InvariantConditions} from "./invariant/InvariantConditions.sol";

/// @dev Defects introduced on purpose. Each defective contract stays in the
///      repository, and each test shows that the checks of the specification tests see it:
///      the same check that holds on the reference implementation fails on the defect.
contract DefectsTest is CompositionChecks, Variant6551 {
    function _reader(address tokenContract) internal returns (CompositionReader) {
        bytes32[] memory tokenCodes = new bytes32[](1);
        tokenCodes[0] = tokenContract.codehash;
        address[] memory implementations = new address[](1);
        implementations[0] = address(implementation);
        bytes32[] memory containerCodes = new bytes32[](1);
        containerCodes[0] = keccak256(type(LockedContainer).runtimeCode);
        return new CompositionReader(tokenCodes, implementations, containerCodes, 200_000, 4_096);
    }

    /// X1 · C3, C4, C5. The account locks `isValidSigner` but validates the holder's signatures
    ///    in `isValidSignature`: a constituent that accepts ERC-1271 authorizations is emptied
    ///    while the token exists.
    function test_Defect_X1_LeakySignatureAccount() public {
        assertTrue(_checkErc1271ConsumerBeforeBurn(), "control: the reference account refuses");

        _useToken(address(new CompositionToken(address(new LeakySignatureAccount()))));
        uint256 tokenId = _mintThree(alice);
        address account = _containerOf(tokenId);
        assertFalse(_checkNoSignerOrSignatureBeforeBurn(tokenId), "C3 sees it");
        bytes32 hash = keccak256("any authorization");
        assertEq(IERC1271(account).isValidSignature(hash, _sign(aliceKey, hash)), ERC1271_MAGIC, "C4 sees it");
        assertFalse(_checkErc1271ConsumerBeforeBurn(), "C5 sees it");

        // what it means: the holder's signature moves a constituent out, the token still alive
        SignatureTransferERC20 sig = new SignatureTransferERC20();
        sig.mint(alice, 10e18);
        vm.prank(alice);
        sig.approve(address(token), type(uint256).max);
        uint256 drained = _mint(alice, alice, _one(address(sig), 10e18));
        address container = _containerOf(drained);
        bytes memory signature = _sign(aliceKey, sig.authorizationDigest(container, alice, 10e18, 7));
        vm.prank(stranger);
        sig.transferWithSignature(container, alice, 10e18, 7, signature);
        assertEq(sig.balanceOf(container), 0, "emptied");
        assertEq(token.ownerOf(drained), alice, "while the token exists");
    }

    /// X2 · C11. A burned id can be minted again; with ERC-6551 it finds the same container.
    function test_Defect_X2_RemintableToken() public {
        assertTrue(_checkRemintRejected(_deployHarness()), "control");
        RemintableCompositionToken remintable = new RemintableCompositionToken(address(implementation));
        assertFalse(_checkRemintRejected(address(remintable)), "C11 sees it");

        // the expropriation: Alice burns and has not withdrawn yet; the id is minted again to
        // Bob, Alice can no longer open the container, Bob burns and takes what was Alice's
        _useToken(address(remintable));
        uint256 tokenId = _mintThree(alice);
        address container = _containerOf(tokenId);
        vm.prank(alice);
        remintable.burn(tokenId);
        remintable.forceMint(bob, tokenId);
        assertEq(_containerOf(tokenId), container, "same container");
        assertEq(remintable.burnedBy(tokenId), address(0), "the record says the token exists");
        assertFalse(_tryExit(alice, container, NATIVE, alice, 1 ether), "Alice is locked out");
        vm.prank(bob);
        remintable.burn(tokenId);
        assertTrue(_tryExit(bob, container, NATIVE, bob, 1 ether), "Bob takes it");
        assertTrue(_tryExit(bob, container, address(tokenX), bob, 10e18));
    }

    /// X3 · A8
    function test_Defect_X3_MutableComposition() public {
        assertTrue(_checkLifecycleValuesNeverChange(), "control");
        _useToken(address(new MutableCompositionToken(address(implementation))));
        assertFalse(_checkLifecycleValuesNeverChange(), "A8 sees it");
    }

    /// X4 · A9, A11
    function test_Defect_X4_EventDiffersFromFunctions() public {
        assertTrue(_checkMintEventMatchesFunctions(), "control");
        _useToken(address(new MismatchedEventToken(address(implementation))));
        assertFalse(_checkMintEventMatchesFunctions(), "A9 sees it");

        vm.recordLogs();
        uint256 tokenId = _mintThree(alice);
        _ingest(address(token), vm.getRecordedLogs());
        assertFalse(_indexAgreesWithFunctions(address(token), tokenId), "A11 sees it");
    }

    /// X5 · A2, A11. The same wrong container in the function and in the event: comparing the
    ///    two finds nothing, comparing either with the expected value does.
    function test_Defect_X5_ConsistentlyWrongContainer() public {
        uint256 control = _mintThree(alice);
        assertTrue(_checkContainerData(control), "control");

        _useToken(address(new ConsistentlyWrongToken(address(implementation))));
        vm.recordLogs();
        uint256 tokenId = _mintThree(alice);
        _ingest(address(token), vm.getRecordedLogs());
        assertTrue(_indexAgreesWithFunctions(address(token), tokenId), "events and functions agree");
        assertFalse(_checkContainerData(tokenId), "A2 sees it");
        assertTrue(
            _index[address(token)][tokenId].account != _predictedContainer(address(token), tokenId), "A11 sees it"
        );
    }

    /// X6 · A10
    function test_Defect_X6_SilentBatch() public {
        vm.recordLogs();
        vm.prank(alice);
        ConsecutiveCompositionToken batch =
            new ConsecutiveCompositionToken{value: 5 ether}(address(implementation), alice, 5, 1 ether);
        assertTrue(_checkBatch(address(batch), vm.getRecordedLogs(), 5), "control");

        vm.recordLogs();
        vm.prank(alice);
        SilentBatchToken silent = new SilentBatchToken{value: 5 ether}(address(implementation), alice, 5, 1 ether);
        assertFalse(_checkBatch(address(silent), vm.getRecordedLogs(), 5), "A10 sees it");
    }

    /// X7 · A5, A6
    function test_Defect_X7_RevertingViews() public {
        assertTrue(_checkNeverMintedIsEmpty(42), "control");
        _useToken(address(new RevertingViewToken(address(implementation))));
        assertFalse(_checkNeverMintedIsEmpty(42), "A5 sees it");
        assertFalse(_checkViewsAnswer(42), "A6 sees it");
    }

    /// X8 · C12
    function test_Defect_X8_NoContainerCheck() public {
        assertTrue(_checkOwnContainerRejected(_mintThree(alice)), "control");
        _useToken(address(new NoOwnContainerCheckToken(address(implementation))));
        assertFalse(_checkOwnContainerRejected(_mintThree(alice)), "C12 sees it");
    }

    /// X9 · C13, C15, C16. Only the token's own container is refused, as in an earlier version
    ///    of this code: a two-piece cycle closes.
    function test_Defect_X9_OwnContainerOnly() public {
        assertTrue(_checkOtherContainerRejected(), "control C13");
        assertTrue(_checkTwoPieceCycleCannotClose(), "control C15");
        assertTrue(_checkChainOfThreeNeverCloses(), "control C16");

        _useToken(address(new OwnContainerOnlyToken(address(implementation))));
        assertTrue(_checkOwnContainerRejected(_mintThree(alice)), "its own container is still refused");
        assertFalse(_checkOtherContainerRejected(), "C13 sees it");
        assertFalse(_checkTwoPieceCycleCannotClose(), "C15 sees it");
        assertFalse(_checkChainOfThreeNeverCloses(), "C16 sees it");
    }

    /// X10 · A3, B5, E1. The container is declared at the registry's address but never created.
    function test_Defect_X10_ContainerNotCreated() public {
        uint256 control = _mintThree(alice);
        assertTrue(_checkContainerIsContract(control) && _checkContainerPassesErc165(control), "control");
        assertEq(
            uint8(_reader(address(token)).verify(address(token), control)), uint8(CompositionReader.Verdict.Verified)
        );

        _useToken(address(new LazyContainerToken(address(implementation))));
        uint256 tokenId = _mintThree(alice);
        assertFalse(_checkContainerIsContract(tokenId), "A3 sees it");
        assertFalse(_checkContainerPassesErc165(tokenId), "B5 sees it");
        assertEq(
            uint8(_reader(address(token)).verify(address(token), tokenId)),
            uint8(CompositionReader.Verdict.ContainerMismatch),
            "E1 sees it"
        );
    }

    /// X11 · C17, E6. Every token reports the container of token 1.
    function test_Defect_X11_SharedContainer() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _mintThree(alice);
        ids[1] = _mintThree(alice);
        assertTrue(_checkContainersDistinct(ids), "control");

        _useToken(address(new SharedContainerToken(address(implementation))));
        ids[0] = _mintThree(alice);
        ids[1] = _mintThree(alice);
        assertFalse(_checkContainersDistinct(ids), "C17 sees it");
        assertEq(
            uint8(_reader(address(token)).verify(address(token), ids[1])),
            uint8(CompositionReader.Verdict.ContainerMismatch),
            "E6 sees it"
        );
    }

    /// X12 · D1, A4. The mint declares what it was asked, without measuring what arrived.
    function test_Defect_X12_UnmeasuredMint() public {
        assertTrue(_checkFeeTokenNeverOverDeclared(), "control");
        _useToken(address(new UnmeasuredMintToken(address(implementation))));
        assertFalse(_checkFeeTokenNeverOverDeclared(), "D1 sees it");

        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(alice, 100e18);
        vm.prank(alice);
        fee.approve(address(token), type(uint256).max);
        uint256 tokenId = _mint(alice, alice, _one(address(fee), 10e18));
        assertFalse(_checkLowerBound(tokenId), "A4 sees it");
    }

    /// X14 · A13, A4. The token is minted before its container is funded. The lower bound
    ///     read when the minting transaction ends is met; the one a recipient reads in
    ///     `onERC721Received` is not.
    function test_Defect_X14_MintBeforeFund() public {
        assertTrue(_checkBackedWhenReceived(), "control");
        _useToken(address(new MintBeforeFundToken(address(implementation))));
        assertFalse(_checkBackedWhenReceived(), "A13 sees it");
        uint256 tokenId = _mintThree(alice);
        assertTrue(_checkLowerBound(tokenId), "a check at the end of the transaction does not");
    }

    /// X13 · C10. The account does not check the chain id.
    function test_Defect_X13_ChainBlindAccount() public {
        assertTrue(_checkOtherChainNothingValidates(_mintThree(alice)), "control");
        _useToken(address(new CompositionToken(address(new ChainBlindAccount()))));
        assertFalse(_checkOtherChainNothingValidates(_mintThree(alice)), "C10 sees it");
    }
}

/// @dev The defects that an invariant also sees: the same fixed sequence runs on the reference
///      and on the defect, and the invariant's own condition is evaluated after it.
contract InvariantDefectsTest is InvariantConditions, Variant6551 {
    /// @dev Points the tests and a new handler at `tokenContract`.
    function _sequenceOn(address tokenContract) internal {
        _useToken(tokenContract);
        handler = new Handler6551(
            tokenContract, address(implementation), alice, bob, carol, stranger, address(tokenX), address(tokenY)
        );
    }

    function _harness() internal returns (address) {
        return address(new CompositionTokenHarness(address(implementation)));
    }

    /// X2 · G6: Alice mints and burns, then the id is minted again to Bob.
    function test_Defect_X2_SeenByInvariant() public {
        address[2] memory tokens = [_harness(), address(new RemintableCompositionToken(address(implementation)))];
        string[2] memory expected = ["", "a burned id exists again 1"];
        for (uint256 i; i < 2; ++i) {
            _sequenceOn(tokens[i]);
            handler.mint(0, 0, 1 ether, 0, 0);
            handler.burn(0, 0);
            handler.tryRemint(1, 1);
            assertEq(_conditionNoBurnedIdReappears(), expected[i]);
        }
    }

    /// X3 · G3: a mint, then a transfer to Bob.
    function test_Defect_X3_SeenByInvariant() public {
        address[2] memory tokens = [_harness(), address(new MutableCompositionToken(address(implementation)))];
        string[2] memory expected = ["", "functions differ from the model 1"];
        for (uint256 i; i < 2; ++i) {
            _sequenceOn(tokens[i]);
            handler.mint(0, 0, 1 ether, 10e18, 0);
            handler.transfer(0, 8);
            assertEq(_conditionDeclarationsNeverChange(), expected[i]);
        }
    }

    /// X4 · G4: a single mint.
    function test_Defect_X4_SeenByInvariant() public {
        address[2] memory tokens = [_harness(), address(new MismatchedEventToken(address(implementation)))];
        string[2] memory expected = ["", "functions differ from the model 1"];
        for (uint256 i; i < 2; ++i) {
            _sequenceOn(tokens[i]);
            handler.mint(0, 0, 1 ether, 10e18, 0);
            assertEq(_conditionFunctionsAndEventsMatchModel(), expected[i]);
        }
    }

    /// X5 · G3, G4: a single mint. The index agrees with the functions, and both differ from the
    ///    model.
    function test_Defect_X5_SeenByInvariant() public {
        address[2] memory tokens = [_harness(), address(new ConsistentlyWrongToken(address(implementation)))];
        string[2] memory functions = ["", "functions differ from the model 1"];
        string[2] memory events = ["", "index differs from the model 1"];
        for (uint256 i; i < 2; ++i) {
            _sequenceOn(tokens[i]);
            handler.mint(0, 0, 1 ether, 10e18, 0);
            assertEq(_conditionDeclarationsNeverChange(), functions[i]);
            assertEq(_conditionFunctionsAndEventsMatchModel(), events[i]);
            assertEq(handler.indexHash(1), _functionsHash(1), "index and functions agree");
        }
    }

    /// X9 · G5: two pieces, each sent into the other's container.
    function test_Defect_X9_SeenByInvariant() public {
        address[2] memory tokens = [_harness(), address(new OwnContainerOnlyToken(address(implementation)))];
        string[2] memory expected = ["", "ownership cycle through piece 1"];
        for (uint256 i; i < 2; ++i) {
            _sequenceOn(tokens[i]);
            handler.mint(0, 0, 1 ether, 0, 0);
            handler.mint(0, 0, 1 ether, 0, 0);
            handler.transfer(0, 13); // piece 1 into the container of piece 2
            handler.transfer(1, 5); // piece 2 into the container of piece 1
            assertEq(_conditionInsideImpliesOlder(), expected[i]);
        }
    }

    /// X12 · G7: a mint with a constituent that keeps a fee on transfer. The reference refuses
    ///     the mint itself, so the sequence stops there; the defect accepts it.
    function test_Defect_X12_SeenByInvariant() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(alice, 100e18);
        address[2] memory tokens = [_harness(), address(new UnmeasuredMintToken(address(implementation)))];
        for (uint256 i; i < 2; ++i) {
            _useToken(tokens[i]);
            vm.prank(alice);
            fee.approve(tokens[i], type(uint256).max);
            handler = new Handler6551(
                tokens[i], address(implementation), alice, bob, carol, stranger, address(tokenX), address(fee)
            );
            if (i == 0) vm.expectRevert(bytes("a mint that had to succeed failed"));
            handler.mint(0, 0, 0, 10e18, 10e18);
        }
        assertEq(_conditionLowerBoundForOrdinaryConstituents(), "below the declared amount 1");
    }
}
