// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Composition} from "../src/IERC721Composition.sol";
import {ConsecutiveCompositionToken} from "../src/ConsecutiveCompositionToken.sol";
import {ILockedContainer} from "../src/LockedContainer.sol";
import {IERC6551Executable} from "../src/interfaces/IERC6551.sol";
import {MockERC20} from "./mocks/Tokens.sol";
import {PlainERC721, EventEmitter, GasMeter} from "./mocks/Misc.sol";
import {Variant, Variant6551, VariantCustom} from "./utils/Variant.sol";
import {Base} from "./Base.t.sol";

/// @dev Group F: orders of magnitude, not promises. `isolate` is set in foundry.toml, so every
///      top-level call that changes state runs as its own transaction and is measured whole,
///      including the base cost of 21,000 gas. Reads are measured as another contract calling
///      them would pay: execution only. Run with `forge test --match-test test_Gas -vv`.
abstract contract GasLog is Base {
    function _last() internal view returns (uint256) {
        return vm.lastFrameGas().gasTotalUsed;
    }

    function _log(string memory label, uint256 gas) internal pure {
        console2.log(label, gas);
    }
}

/// @dev F1, written once and run on both container types.
abstract contract GasSpec is GasLog, Variant {
    function setUp() public virtual override(Base, Variant) {
        Variant.setUp();
    }

    /// @dev Moves `amount` of `asset` out of `container` as `caller`, in one top-level call.
    function _exit(address caller, address container, address asset, uint256 amount) internal virtual;

    /// @dev Native asset, the two shared ERC-20 and five more, sorted.
    function _eight() internal returns (IERC721Composition.Constituent[] memory c) {
        c = new IERC721Composition.Constituent[](8);
        c[0] = IERC721Composition.Constituent(NATIVE, 1 ether);
        c[1] = IERC721Composition.Constituent(address(tokenX), 10e18);
        c[2] = IERC721Composition.Constituent(address(tokenY), 20e18);
        for (uint256 i; i < 5; ++i) {
            MockERC20 extra = new MockERC20("Extra", "EXT");
            extra.mint(alice, 1_000e18);
            vm.prank(alice);
            extra.approve(address(token), type(uint256).max);
            c[3 + i] = IERC721Composition.Constituent(address(extra), 1e18);
        }
        _sort(c);
    }

    /// F1
    function test_Gas_Report() public {
        PlainERC721 plain = new PlainERC721();
        plain.mint(alice, 1);
        _log("plain ERC-721 mint                  ", _last());
        vm.prank(alice);
        plain.transferFrom(alice, bob, 1);
        _log("plain ERC-721 transfer              ", _last());
        plain.ownerOf(1);
        _log("plain ERC-721 ownerOf, read         ", _last());

        IERC721Composition.Constituent[] memory one = _one(NATIVE, 1 ether);
        IERC721Composition.Constituent[] memory three = _three(1 ether, 10e18, 20e18);
        IERC721Composition.Constituent[] memory eight = _eight();

        vm.prank(alice);
        uint256 a = token.mint{value: 1 ether}(alice, one);
        _log("mint, 1 constituent                 ", _last());
        vm.prank(alice);
        uint256 b = token.mint{value: 1 ether}(alice, three);
        _log("mint, 3 constituents                ", _last());
        vm.prank(alice);
        uint256 c = token.mint{value: 1 ether}(alice, eight);
        _log("mint, 8 constituents                ", _last());

        vm.prank(alice);
        token.transferFrom(alice, bob, a);
        _log("transfer, with the container check  ", _last());

        token.compositionOf(a);
        _log("compositionOf, 1 constituent, read  ", _last());
        token.compositionOf(b);
        _log("compositionOf, 3 constituents, read ", _last());
        token.compositionOf(c);
        _log("compositionOf, 8 constituents, read ", _last());
        token.compositionAccountOf(b);
        _log("compositionAccountOf, read          ", _last());

        address container = _containerOf(b);
        vm.prank(alice);
        token.burn(b);
        _log("burn                                ", _last());
        _exit(alice, container, NATIVE, 1 ether);
        _log("withdraw native asset after burn    ", _last());
        _exit(alice, container, address(tokenX), 10e18);
        _log("withdraw ERC-20 after burn          ", _last());
    }
}

contract GasERC6551Test is GasSpec, Variant6551 {
    function setUp() public override(GasSpec, Variant) {
        GasSpec.setUp();
    }

    function _exit(address caller, address container, address asset, uint256 amount) internal override {
        (address target, uint256 value, bytes memory data) = asset == NATIVE
            ? (caller, amount, bytes(""))
            : (asset, uint256(0), abi.encodeCall(IERC20.transfer, (caller, amount)));
        vm.prank(caller);
        IERC6551Executable(payable(container)).execute(target, value, data, 0);
    }
}

contract GasCustomContainerTest is GasSpec, VariantCustom {
    function setUp() public override(GasSpec, Variant) {
        GasSpec.setUp();
    }

    function _exit(address caller, address container, address asset, uint256 amount) internal override {
        vm.prank(caller);
        ILockedContainer(container).withdraw(asset, caller, amount);
    }
}

/// @dev F2 and F3, on the ERC-6551 variant only.
contract GasTest is GasLog {
    /// F2. Contract creation is measured with gasleft around the creation, so
    ///      the figures exclude the base transaction cost: the marginal cost does not need it.
    function test_Gas_BatchConstructor() public {
        uint256 start = gasleft();
        new ConsecutiveCompositionToken{value: 10 ether}(address(implementation), alice, 10, 1 ether);
        uint256 ten = start - gasleft();
        start = gasleft();
        new ConsecutiveCompositionToken{value: 20 ether}(address(implementation), alice, 20, 1 ether);
        uint256 twenty = start - gasleft();
        _log("batch of 10, constructor            ", ten);
        _log("batch of 20, constructor            ", twenty);
        _log("marginal cost per token in a batch  ", (twenty - ten) / 10);
        assertGt(twenty, ten);
    }

    /// F3. The event alone, against the same call without it. Both
    ///      calls go through a meter: measured as transactions, the call without the event
    ///      would pay the calldata floor of EIP-7623 instead of its execution, and the
    ///      difference would come out smaller than the event costs.
    function test_Gas_EventShare() public {
        EventEmitter emitter = new EventEmitter();
        GasMeter meter = new GasMeter();
        bytes memory data = abi.encode(address(implementation), bytes32(0));
        address account = makeAddr("account");

        uint256 baseline =
            meter.measure(address(emitter), abi.encodeCall(EventEmitter.noop, (account, data, NATIVE, 1 ether)));
        uint256 withEvent =
            meter.measure(address(emitter), abi.encodeCall(EventEmitter.emitOne, (account, data, NATIVE, 1 ether)));
        _log("event, 1 constituent, per id        ", withEvent - baseline);

        IERC721Composition.Constituent[] memory c = _three(1 ether, 10e18, 20e18);
        baseline = meter.measure(address(emitter), abi.encodeCall(EventEmitter.noopThree, (account, data, c)));
        withEvent = meter.measure(address(emitter), abi.encodeCall(EventEmitter.emitThree, (account, data, c)));
        _log("event, 3 constituents, per id       ", withEvent - baseline);
    }
}
