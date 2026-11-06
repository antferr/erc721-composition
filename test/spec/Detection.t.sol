// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {IERC6551Account, IERC6551Executable} from "../../src/interfaces/IERC6551.sol";
import {Base} from "../Base.t.sol";

/// @dev A0, B1, B2 and B4: setup and detection, independent of the container type.
contract DetectionTest is Base {
    /// A0 · I3. The code at the canonical registry address is the runtime code contained in the
    ///      deployment data printed in the ERC-6551 text (salt, 32-byte constructor, then 0x23b
    ///      bytes of runtime code). setUp has already checked that Nick's factory, given those
    ///      data, lands on the canonical address: CREATE2 ties that address to the code.
    function test_Setup_CanonicalRegistry() public view {
        bytes memory data = vm.parseBytes(vm.readFile("test/data/erc6551-registry-deploy-data.txt"));
        assertEq(data.length, 32 + 32 + 0x23b);
        bytes memory runtime = new bytes(0x23b);
        for (uint256 i; i < runtime.length; ++i) {
            runtime[i] = data[64 + i];
        }
        assertEq(REGISTRY.code, runtime);
    }

    /// B1 · I1
    function test_InterfaceId_IsXorOfSelectors() public pure {
        bytes4 a = bytes4(keccak256("compositionOf(uint256)"));
        bytes4 b = bytes4(keccak256("compositionAccountOf(uint256)"));
        assertEq(a, bytes4(0x318d4866));
        assertEq(b, bytes4(0xe7872418));
        assertEq(a ^ b, type(IERC721Composition).interfaceId);
        assertEq(type(IERC721Composition).interfaceId, bytes4(0xd60a6c7e));
    }

    /// B2 · I1, method. The same computation reproduces identifiers published in other ERCs.
    function test_InterfaceId_MethodReproducesPublishedIds() public pure {
        bytes4 erc721 = bytes4(keccak256("balanceOf(address)")) ^ bytes4(keccak256("ownerOf(uint256)"))
            ^ bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"))
            ^ bytes4(keccak256("safeTransferFrom(address,address,uint256)"))
            ^ bytes4(keccak256("transferFrom(address,address,uint256)")) ^ bytes4(keccak256("approve(address,uint256)"))
            ^ bytes4(keccak256("setApprovalForAll(address,bool)")) ^ bytes4(keccak256("getApproved(uint256)"))
            ^ bytes4(keccak256("isApprovedForAll(address,address)"));
        assertEq(erc721, bytes4(0x80ac58cd));
        assertEq(type(IERC721).interfaceId, bytes4(0x80ac58cd));

        bytes4 account = bytes4(keccak256("token()")) ^ bytes4(keccak256("state()"))
            ^ bytes4(keccak256("isValidSigner(address,bytes)"));
        assertEq(account, bytes4(0x6faff5f1));
        assertEq(type(IERC6551Account).interfaceId, bytes4(0x6faff5f1));
        assertEq(type(IERC6551Executable).interfaceId, bytes4(0x51945447));

        assertEq(bytes4(keccak256("burnedBy(uint256)")), bytes4(0x43470a89));
        assertEq(type(IERC721BurnRecord).interfaceId, bytes4(0x43470a89));
        assertEq(bytes4(keccak256("isValidSignature(bytes32,bytes)")), bytes4(0x1626ba7e));
        assertEq(type(IERC1271).interfaceId, bytes4(0x1626ba7e));
    }

    /// B4 · I4
    function test_EventSignatureAndTopic() public pure {
        bytes32 topic = keccak256("CompositionDeclared(uint256,address,bytes4,bytes,(address,uint256)[])");
        assertEq(IERC721Composition.CompositionDeclared.selector, topic);
        assertEq(topic, 0x6c271b39522a106c25f713cdb3e6d8ae6cb22ff3fabee0cbe30f8146c4db6cec);
    }
}
