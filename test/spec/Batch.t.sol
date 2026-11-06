// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {ERC721Composition} from "../../src/ERC721Composition.sol";
import {ConsecutiveCompositionToken} from "../../src/ConsecutiveCompositionToken.sol";
import {IERC6551Executable} from "../../src/interfaces/IERC6551.sol";
import {Variant6551} from "../utils/Variant.sol";
import {CompositionChecks} from "./Checks.sol";

/// @dev A10, C14 and the batch parts of B3 and C17: tokens minted in batch during construction,
///      where ERC-721 allows creating tokens without a Transfer event for each one.
contract BatchTest is CompositionChecks, Variant6551 {
    uint96 internal constant BATCH = 5;

    function _deployBatch(address receiver) internal returns (ConsecutiveCompositionToken batch, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(alice);
        batch =
            new ConsecutiveCompositionToken{value: BATCH * 1 ether}(address(implementation), receiver, BATCH, 1 ether);
        logs = vm.getRecordedLogs();
    }

    /// A10 · P6, P10, I4
    function test_Batch_EventAndContainerForEveryId() public {
        (ConsecutiveCompositionToken batch, Vm.Log[] memory logs) = _deployBatch(alice);
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 consecutiveTopic = keccak256("ConsecutiveTransfer(uint256,uint256,address,address)");
        uint256 transfers;
        uint256 consecutive;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(batch)) continue;
            if (logs[i].topics[0] == transferTopic) ++transfers;
            if (logs[i].topics[0] == consecutiveTopic) ++consecutive;
        }
        assertEq(transfers, 0, "no Transfer in a batch mint");
        assertEq(consecutive, 1, "one ConsecutiveTransfer");
        assertTrue(_checkBatch(address(batch), logs, BATCH), "one event per id, same data, containers deployed");

        // a batch-minted token burns and opens like any other
        (address account,,) = batch.compositionAccountOf(3);
        vm.prank(alice);
        batch.burn(3);
        assertEq(batch.burnedBy(3), alice);
        vm.prank(alice);
        IERC6551Executable(payable(account)).execute(alice, 1 ether, "", 0);
        assertEq(account.balance, 0);
    }

    /// B3, batch part · I1
    function test_Batch_SupportsInterface() public {
        (ConsecutiveCompositionToken batch,) = _deployBatch(alice);
        assertTrue(batch.supportsInterface(COMPOSITION_ID));
        assertTrue(batch.supportsInterface(BURN_RECORD_ID));
        assertTrue(batch.supportsInterface(0x80ac58cd));
        assertTrue(batch.supportsInterface(0x01ffc9a7));
        assertFalse(batch.supportsInterface(0xffffffff));
    }

    /// C14 · P12. The receiver of the batch is the container of id 3.
    function test_Batch_ReceiverIsBatchContainer_Rejected() public {
        address receiver = _expected6551(address(implementation), _nextContractAddress(alice), 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, 0, 3));
        new ConsecutiveCompositionToken{value: BATCH * 1 ether}(address(implementation), receiver, BATCH, 1 ether);
    }

    /// C17, batch part · P3
    function test_Batch_ContainersAreDistinct() public {
        (ConsecutiveCompositionToken batch,) = _deployBatch(alice);
        _useToken(address(batch));
        uint256[] memory ids = new uint256[](BATCH);
        for (uint256 i; i < BATCH; ++i) {
            ids[i] = i;
        }
        assertTrue(_checkContainersDistinct(ids));
    }

    function _nextContractAddress(address deployer) internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer));
    }
}
