// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";
import {IERC721Composition} from "../IERC721Composition.sol";
import {IERC6551Registry} from "../interfaces/IERC6551.sol";
import {ILockedContainer} from "../LockedContainer.sol";

/// @title Example reader: what a contract that knows nothing about a collection can verify
/// @notice Uses only what the interfaces return, plus the reader's own review of code. The
///         container obeys `burnedBy`, so the reader recognizes two pieces of code: the
///         container's and the token contract's. Which code counts as reviewed is the reader's
///         decision, fixed here at construction.
/// @dev Safe to point at any contract: interface detection follows the ERC-165 procedure, and
///      every other call to code that has not been recognized yet runs with a gas limit and a
///      cap on the data it returns, so that a hostile contract can neither revert the reader
///      nor make it pay for copying an enormous answer. Malformed answers count as "not
///      supported". Balances are read from the constituents, never from events.
contract CompositionReader {
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes4 internal constant ERC6551_ACCOUNT_INTERFACE_ID = 0x6faff5f1;
    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    enum Verdict {
        NotSupported,
        NotDeclared,
        UnrecognizedTokenContract,
        UnknownContainerType,
        ContainerMismatch,
        UnrecognizedContainerCode,
        Verified
    }

    /// @notice Gas given to each call into code that has not been recognized.
    uint256 public immutable callGas;
    /// @notice Largest answer, in bytes, that the reader accepts and copies.
    uint256 public immutable maxReturnBytes;

    mapping(bytes32 codeHash => bool) public recognizedTokenCode;
    mapping(address implementation => bool) public recognizedAccountImplementation;
    mapping(bytes32 codeHash => bool) public recognizedContainerCode;

    constructor(
        bytes32[] memory tokenCodeHashes,
        address[] memory accountImplementations,
        bytes32[] memory containerCodeHashes,
        uint256 callGas_,
        uint256 maxReturnBytes_
    ) {
        for (uint256 i; i < tokenCodeHashes.length; ++i) {
            recognizedTokenCode[tokenCodeHashes[i]] = true;
        }
        for (uint256 i; i < accountImplementations.length; ++i) {
            recognizedAccountImplementation[accountImplementations[i]] = true;
        }
        for (uint256 i; i < containerCodeHashes.length; ++i) {
            recognizedContainerCode[containerCodeHashes[i]] = true;
        }
        callGas = callGas_;
        maxReturnBytes = maxReturnBytes_;
    }

    /// @notice What a token contract answers about one token, read without trusting it.
    struct Answer {
        bool supported;
        IERC721Composition.Constituent[] constituents;
        address account;
        bytes4 accountType;
        bytes accountData;
    }

    /// @notice Reads the declaration without trusting the contract, and never reverts.
    ///         `supported` is false if the interfaces are not detected or an answer is
    ///         missing, too long or malformed; the other fields are then empty.
    function read(address token, uint256 tokenId) public view returns (Answer memory answer) {
        if (
            !ERC165Checker.supportsInterface(token, type(IERC721Composition).interfaceId)
                || !ERC165Checker.supportsERC165InterfaceUnchecked(token, type(IERC721BurnRecord).interfaceId)
        ) return answer;

        (bool ok, bytes memory data) =
            _boundedStaticcall(token, abi.encodeCall(IERC721Composition.compositionOf, (tokenId)));
        if (!ok) return answer;
        try this.decodeComposition(data) returns (IERC721Composition.Constituent[] memory constituents) {
            answer.constituents = constituents;
        } catch {
            return answer;
        }

        (ok, data) = _boundedStaticcall(token, abi.encodeCall(IERC721Composition.compositionAccountOf, (tokenId)));
        if (ok) {
            try this.decodeAccount(data) returns (address account, bytes4 accountType, bytes memory accountData) {
                answer.account = account;
                answer.accountType = accountType;
                answer.accountData = accountData;
                answer.supported = true;
                return answer;
            } catch {}
        }
        delete answer.constituents;
    }

    /// @notice Checks interfaces, the declaration, the container's identity and the code.
    function verify(address token, uint256 tokenId) public view returns (Verdict verdict) {
        (verdict,) = _verify(token, tokenId);
    }

    /// @notice The verdict, the declared composition and the container's current balances.
    ///         Composition and balances are returned only for a verified token, and
    ///         `atLeastDeclared` says whether the container holds every declared amount now.
    function inspect(address token, uint256 tokenId)
        external
        view
        returns (
            Verdict verdict,
            IERC721Composition.Constituent[] memory constituents,
            uint256[] memory balances,
            bool atLeastDeclared
        )
    {
        Answer memory answer;
        (verdict, answer) = _verify(token, tokenId);
        if (verdict != Verdict.Verified) return (verdict, constituents, balances, false);
        constituents = answer.constituents;
        balances = new uint256[](constituents.length);
        atLeastDeclared = true;
        for (uint256 i; i < constituents.length; ++i) {
            balances[i] = _balanceOf(constituents[i].asset, answer.account);
            if (balances[i] < constituents[i].amount) atLeastDeclared = false;
        }
    }

    function _verify(address token, uint256 tokenId) internal view returns (Verdict, Answer memory answer) {
        answer = read(token, tokenId);
        if (!answer.supported) return (Verdict.NotSupported, answer);
        // an empty composition means "not declared", never "declared as zero"
        if (answer.account == address(0) || answer.constituents.length == 0) return (Verdict.NotDeclared, answer);
        if (!recognizedTokenCode[token.codehash]) return (Verdict.UnrecognizedTokenContract, answer);
        if (answer.account.code.length == 0 || !ERC165Checker.supportsInterface(answer.account, answer.accountType)) {
            return (Verdict.ContainerMismatch, answer);
        }
        if (answer.accountType == ERC6551_ACCOUNT_INTERFACE_ID) {
            return (_verifyERC6551Account(token, tokenId, answer.account, answer.accountData), answer);
        }
        if (answer.accountType == type(ILockedContainer).interfaceId) {
            return (_verifyCustomContainer(token, tokenId, answer.account), answer);
        }
        return (Verdict.UnknownContainerType, answer);
    }

    /// @dev The account must be the one the canonical registry computes for this chain, this
    ///      contract and this id, with a recognized implementation. Recognizing that one address
    ///      is enough only because the implementation can neither be upgraded nor delegate.
    function _verifyERC6551Account(address token, uint256 tokenId, address account, bytes memory accountData)
        internal
        view
        returns (Verdict)
    {
        if (accountData.length != 64) return Verdict.ContainerMismatch;
        (uint256 implementationWord, bytes32 salt) = abi.decode(accountData, (uint256, bytes32));
        if (implementationWord >> 160 != 0) return Verdict.ContainerMismatch;
        address implementation = address(uint160(implementationWord));
        address expected =
            IERC6551Registry(ERC6551_REGISTRY).account(implementation, salt, block.chainid, token, tokenId);
        if (expected != account) return Verdict.ContainerMismatch;
        if (!recognizedAccountImplementation[implementation]) return Verdict.UnrecognizedContainerCode;
        return Verdict.Verified;
    }

    /// @dev The container's code must be recognized, and only then is it asked which token it
    ///      belongs to.
    function _verifyCustomContainer(address token, uint256 tokenId, address account) internal view returns (Verdict) {
        if (!recognizedContainerCode[account.codehash]) return Verdict.UnrecognizedContainerCode;
        (uint256 chainId, address boundToken, uint256 boundId) = ILockedContainer(account).token();
        if (chainId != block.chainid || boundToken != token || boundId != tokenId) return Verdict.ContainerMismatch;
        return Verdict.Verified;
    }

    /// @dev External only so that a malformed answer can be caught with try/catch.
    function decodeComposition(bytes calldata answer) external pure returns (IERC721Composition.Constituent[] memory) {
        return abi.decode(answer, (IERC721Composition.Constituent[]));
    }

    /// @dev External only so that a malformed answer can be caught with try/catch.
    function decodeAccount(bytes calldata answer) external pure returns (address, bytes4, bytes memory) {
        return abi.decode(answer, (address, bytes4, bytes));
    }

    /// @dev Native balance, or the ERC-20 balance read with the same limits as any other call.
    ///      A constituent that fails to answer counts as a zero balance.
    function _balanceOf(address asset, address account) internal view returns (uint256) {
        if (asset == NATIVE_ASSET) return account.balance;
        (bool ok, bytes memory answer) = _boundedStaticcall(asset, abi.encodeCall(IERC20.balanceOf, (account)));
        if (!ok || answer.length != 32) return 0;
        return abi.decode(answer, (uint256));
    }

    /// @dev A read-only call with {callGas} gas that copies the answer only if it is at most
    ///      {maxReturnBytes} long. The gas limit protects against a callee that burns gas; the
    ///      cap protects against one that returns so much data that copying it would.
    function _boundedStaticcall(address target, bytes memory data)
        internal
        view
        returns (bool ok, bytes memory answer)
    {
        uint256 gasLimit = callGas;
        uint256 maxBytes = maxReturnBytes;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(data, 0x20), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!ok || size > maxBytes) return (false, answer);
        answer = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(answer, 0x20), 0, size)
        }
    }
}
