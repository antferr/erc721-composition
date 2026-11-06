// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Variant, Variant6551, VariantCustom} from "../utils/Variant.sol";
import {CompositionHandler, Handler6551, HandlerCustom} from "./CompositionHandler.sol";
import {InvariantConditions} from "./InvariantConditions.sol";

/// @dev Group G: random sequences of mints, transfers, approvals, burns, deposits and attempts
///      to take assets out, on both container types. After every step, functions and events
///      are compared with the handler's model. The token is the reference token with the
///      internal mint exposed, used only to attempt mints that must fail.
abstract contract InvariantSpec is InvariantConditions {
    function _deployHandler() internal virtual returns (CompositionHandler);

    function setUp() public virtual override {
        super.setUp();
        _useToken(_deployHarness());
        handler = _deployHandler();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: handler.actions()}));
    }

    // ------------------------------------------------------------ invariants

    /// G1 · P1, FT4
    function invariant_NothingLeavesBeforeBurn() public view {
        assertEq(_conditionNothingLeavesBeforeBurn(), "");
    }

    /// G2 · P1, BR2, BR5
    function invariant_OnlyBurnerWithdraws() public view {
        assertEq(_conditionOnlyBurnerWithdraws(), "");
    }

    /// G3 · P4, P8
    function invariant_DeclarationsNeverChange() public view {
        assertEq(_conditionDeclarationsNeverChange(), "");
    }

    /// G4 · P6, FT1-FT3
    function invariant_FunctionsAndEventsMatchModel() public view {
        assertEq(_conditionFunctionsAndEventsMatchModel(), "");
    }

    /// G5 · P12
    function invariant_InsideImpliesOlder() public view {
        assertEq(_conditionInsideImpliesOlder(), "");
    }

    /// G6 · P7, BR4
    function invariant_NoBurnedIdReappears() public view {
        assertEq(_conditionNoBurnedIdReappears(), "");
    }

    /// G7 · P5
    function invariant_LowerBoundForOrdinaryConstituents() public view {
        assertEq(_conditionLowerBoundForOrdinaryConstituents(), "");
    }

    // ------------------------------------------------------------ reach

    /// @dev Not an invariant: twenty fixed pseudo-random sequences of 100 actions, each on a new
    ///      token and handler, as the fuzzer runs them. Shows that the handler reaches every
    ///      case the invariants are meant to cover, and checks them at the end of each sequence.
    function test_Handler_ReachesEveryCase() public {
        string[] memory cases = _cases();
        uint256[] memory counts = new uint256[](cases.length);
        for (uint256 s; s < 20; ++s) {
            if (s != 0) {
                _useToken(_deployHarness());
                handler = _deployHandler();
            }
            bytes4[] memory list = handler.actions();
            for (uint256 i; i < 100; ++i) {
                uint256 seed = uint256(keccak256(abi.encode(s, i)));
                uint256[5] memory args;
                for (uint256 j; j < 5; ++j) {
                    args[j] = uint256(keccak256(abi.encode(seed, j)));
                }
                (bool ok,) = address(handler).call(_encode(list[seed % list.length], args));
                assertTrue(ok, "handler action failed");
            }
            invariant_NothingLeavesBeforeBurn();
            invariant_OnlyBurnerWithdraws();
            invariant_DeclarationsNeverChange();
            invariant_FunctionsAndEventsMatchModel();
            invariant_InsideImpliesOlder();
            invariant_NoBurnedIdReappears();
            invariant_LowerBoundForOrdinaryConstituents();
            for (uint256 c; c < cases.length; ++c) {
                counts[c] += handler.reached(bytes32(bytes(cases[c])));
            }
        }
        for (uint256 c; c < cases.length; ++c) {
            assertGt(counts[c], 0, cases[c]);
        }
    }

    /// @dev The cases every sequence set must reach; variants add their own.
    function _cases() internal pure virtual returns (string[] memory list) {
        list = new string[](19);
        list[0] = "mint";
        list[1] = "mint into future container";
        list[2] = "mint into declared container";
        list[3] = "transfer";
        list[4] = "transfer into future container";
        list[5] = "transfer into declared container";
        list[6] = "transfer into own container";
        list[7] = "approval";
        list[8] = "burn by owner";
        list[9] = "burn by operator";
        list[10] = "burn refused";
        list[11] = "deposit";
        list[12] = "deposit before mint";
        list[13] = "exit refused before burn";
        list[14] = "exit refused after burn";
        list[15] = "piece exit refused";
        list[16] = "withdrawal by burner";
        list[17] = "withdrawal by contract burner";
        list[18] = "remint of burned id";
    }

    function _append(string[] memory list, string[] memory more) internal pure returns (string[] memory all) {
        all = new string[](list.length + more.length);
        for (uint256 i; i < list.length; ++i) {
            all[i] = list[i];
        }
        for (uint256 i; i < more.length; ++i) {
            all[list.length + i] = more[i];
        }
    }

    // ------------------------------------------------------------ helpers

    function _encode(bytes4 selector, uint256[5] memory a) internal view returns (bytes memory) {
        if (selector == handler.mint.selector) return abi.encodeWithSelector(selector, a[0], a[1], a[2], a[3], a[4]);
        if (selector == handler.transfer.selector) return abi.encodeWithSelector(selector, a[0], a[1]);
        if (selector == handler.approve.selector) return abi.encodeWithSelector(selector, a[0], a[1], a[2] % 2 == 0);
        if (selector == handler.burn.selector) return abi.encodeWithSelector(selector, a[0], a[1]);
        if (selector == handler.deposit.selector) return abi.encodeWithSelector(selector, a[0], a[1], a[2], a[3]);
        if (selector == handler.tryWithdraw.selector) return abi.encodeWithSelector(selector, a[0], a[1], a[2], a[3]);
        if (selector == handler.withdrawAsBurner.selector) return abi.encodeWithSelector(selector, a[0], a[1], a[2]);
        if (selector == handler.tryRemint.selector) return abi.encodeWithSelector(selector, a[0], a[1]);
        return abi.encodeWithSelector(selector, a[0]);
    }
}

contract InvariantERC6551Test is InvariantSpec, Variant6551 {
    function setUp() public override(InvariantSpec, Variant) {
        InvariantSpec.setUp();
    }

    function _deployHandler() internal override returns (CompositionHandler) {
        return new Handler6551(
            address(token), address(implementation), alice, bob, carol, stranger, address(tokenX), address(tokenY)
        );
    }

    function _cases() internal pure override returns (string[] memory) {
        string[] memory more = new string[](3);
        more[0] = "account created in advance";
        more[1] = "mint into created account";
        more[2] = "burner takes a piece back";
        return _append(super._cases(), more);
    }
}

contract InvariantCustomContainerTest is InvariantSpec, VariantCustom {
    function setUp() public override(InvariantSpec, Variant) {
        InvariantSpec.setUp();
    }

    function _deployHandler() internal override returns (CompositionHandler) {
        return new HandlerCustom(address(token), alice, bob, carol, stranger, address(tokenX), address(tokenY));
    }
}
