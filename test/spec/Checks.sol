// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {ERC721Composition} from "../../src/ERC721Composition.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551.sol";
import {FeeOnTransferERC20, SignatureTransferERC20} from "../mocks/Tokens.sol";
import {Holder} from "../mocks/Holders.sol";
import {Variant, ICompositionToken, IForceMint} from "../utils/Variant.sol";

/// @dev The checks of the specification tests, written to return an outcome instead of stopping
///      the test. The specification tests require a positive outcome on the reference
///      implementation; the defect tests require a negative one on the defective contracts. The
///      same check therefore proves both that the reference passes and that the defect is seen.
abstract contract CompositionChecks is Variant {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    /// @dev What an indexer rebuilds from the logs alone.
    struct Indexed {
        bool declared;
        address account;
        bytes4 accountType;
        bytes accountData;
        bytes composition;
        address burner;
    }

    mapping(address tokenContract => mapping(uint256 tokenId => Indexed)) internal _index;

    /// @dev A rejection counts only if it carries the expected error: a call that fails for an
    ///      unrelated reason, such as a test calling from the wrong address, must not pass a
    ///      check that expects a rejection.
    function _hasSelector(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        return reason.length >= 4 && bytes4(reason) == selector;
    }

    // ------------------------------------------------------------ declaration (group A)

    /// @dev The common check after every mint: P9, P10, I2, I3.
    function _checkConformance(uint256 tokenId) internal view returns (bool) {
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        if (c.length == 0) return false;
        address previous;
        for (uint256 i; i < c.length; ++i) {
            if (c[i].asset <= previous || c[i].amount == 0) return false;
            previous = c[i].asset;
        }
        (address account, bytes4 accountType,) = token.compositionAccountOf(tokenId);
        if (account == address(0) || account.code.length == 0) return false;
        return ERC165Checker.supportsInterface(account, accountType);
    }

    function _checkContainerData(uint256 tokenId) internal view returns (bool) {
        (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(tokenId);
        return account == _predictedContainer(address(token), tokenId) && accountType == _expectedType()
            && keccak256(accountData) == keccak256(_expectedData(address(token)));
    }

    function _checkContainerIsContract(uint256 tokenId) internal view returns (bool) {
        return _containerOf(tokenId).code.length != 0;
    }

    function _checkContainerPassesErc165(uint256 tokenId) internal view returns (bool) {
        (address account, bytes4 accountType,) = token.compositionAccountOf(tokenId);
        return
            ERC165Checker.supportsERC165(account)
                && ERC165Checker.supportsERC165InterfaceUnchecked(account, accountType);
    }

    function _checkLowerBound(uint256 tokenId) internal view returns (bool) {
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        address account = _containerOf(tokenId);
        for (uint256 i; i < c.length; ++i) {
            if (_balance(c[i].asset, account) < c[i].amount) return false;
        }
        return true;
    }

    /// @dev A constituent that keeps a fee on every transfer: either the mint fails, or the
    ///      container ends up with at least what is declared.
    function _checkFeeTokenNeverOverDeclared() internal returns (bool) {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(alice, 100e18);
        vm.prank(alice);
        fee.approve(address(token), type(uint256).max);
        vm.prank(alice);
        try token.mint(alice, _one(address(fee), 10e18)) returns (uint256 tokenId) {
            return _checkLowerBound(tokenId);
        } catch {
            return true;
        }
    }

    function _checkViewsAnswer(uint256 tokenId) internal view returns (bool) {
        try token.compositionOf(tokenId) returns (IERC721Composition.Constituent[] memory) {}
        catch {
            return false;
        }
        try token.compositionAccountOf(tokenId) returns (address, bytes4, bytes memory) {}
        catch {
            return false;
        }
        return true;
    }

    function _checkNeverMintedIsEmpty(uint256 tokenId) internal view returns (bool) {
        if (!_checkViewsAnswer(tokenId)) return false;
        (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(tokenId);
        return token.compositionOf(tokenId).length == 0 && account == address(0) && accountType == bytes4(0)
            && accountData.length == 0;
    }

    /// @dev Mint, approval, transfer, unannounced deposit, burn by the new owner, withdrawal:
    ///      after every step the two functions return what they returned at mint.
    function _checkLifecycleValuesNeverChange() internal returns (bool) {
        uint256 tokenId = _mintThree(alice);
        bytes32 expected = keccak256(_encodedDeclaration(tokenId));
        address account = _containerOf(tokenId);

        vm.prank(alice);
        token.approve(carol, tokenId);
        if (keccak256(_encodedDeclaration(tokenId)) != expected) return false;
        vm.prank(alice);
        token.transferFrom(alice, bob, tokenId);
        if (keccak256(_encodedDeclaration(tokenId)) != expected) return false;
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = account.call{value: 0.5 ether}("");
        if (!sent || keccak256(_encodedDeclaration(tokenId)) != expected) return false;
        vm.prank(bob);
        token.burn(tokenId);
        if (keccak256(_encodedDeclaration(tokenId)) != expected) return false;
        if (!_tryExit(bob, account, NATIVE, bob, 0.5 ether)) return false;
        return keccak256(_encodedDeclaration(tokenId)) == expected;
    }

    /// @dev One event at mint, with the data of the two functions; none afterwards.
    function _checkMintEventMatchesFunctions() internal returns (bool) {
        vm.recordLogs();
        uint256 tokenId = _mintThree(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (
            uint256[] memory ids,
            address[] memory accounts,
            bytes4[] memory types,
            bytes[] memory datas,
            IERC721Composition.Constituent[][] memory compositions
        ) = _declaredEvents(logs, address(token));
        if (ids.length != 1 || ids[0] != tokenId) return false;
        (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(tokenId);
        if (accounts[0] != account || types[0] != accountType || keccak256(datas[0]) != keccak256(accountData)) {
            return false;
        }
        if (keccak256(abi.encode(compositions[0])) != keccak256(abi.encode(token.compositionOf(tokenId)))) {
            return false;
        }

        vm.recordLogs();
        vm.prank(alice);
        token.approve(carol, tokenId);
        vm.prank(alice);
        token.transferFrom(alice, bob, tokenId);
        vm.prank(bob);
        token.burn(tokenId);
        _tryExit(bob, account, NATIVE, bob, 1 ether);
        (ids,,,,) = _declaredEvents(vm.getRecordedLogs(), address(token));
        return ids.length == 0;
    }

    /// @dev Batch minted during construction: one event per id, the data of the functions, and
    ///      every container already a contract.
    function _checkBatch(address batch, Vm.Log[] memory logs, uint256 batchSize) internal view returns (bool) {
        (uint256[] memory ids, address[] memory accounts,,, IERC721Composition.Constituent[][] memory compositions) =
            _declaredEvents(logs, batch);
        if (ids.length != batchSize) return false;
        for (uint256 i; i < batchSize; ++i) {
            if (ids[i] != i) return false;
            (address account,,) = IERC721Composition(batch).compositionAccountOf(i);
            if (accounts[i] != account || account.code.length == 0) return false;
            if (
                keccak256(abi.encode(compositions[i]))
                    != keccak256(abi.encode(IERC721Composition(batch).compositionOf(i)))
            ) return false;
        }
        return true;
    }

    // ------------------------------------------------------------ indexer (A11, G4, X5)

    /// @dev Feeds the logs of one step to the indexer: declarations from CompositionDeclared,
    ///      burners from Transfer to the zero address. Balances are never taken from logs.
    function _ingest(address tokenContract, Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != tokenContract) continue;
            if (l.topics[0] == IERC721Composition.CompositionDeclared.selector) {
                uint256 tokenId = uint256(l.topics[1]);
                Indexed storage entry = _index[tokenContract][tokenId];
                entry.declared = true;
                entry.account = address(uint160(uint256(l.topics[2])));
                (bytes4 accountType, bytes memory accountData, IERC721Composition.Constituent[] memory c) =
                    abi.decode(l.data, (bytes4, bytes, IERC721Composition.Constituent[]));
                entry.accountType = accountType;
                entry.accountData = accountData;
                entry.composition = abi.encode(c);
            } else if (l.topics[0] == TRANSFER_TOPIC && l.topics.length == 4 && l.topics[2] == bytes32(0)) {
                _index[tokenContract][uint256(l.topics[3])].burner = address(uint160(uint256(l.topics[1])));
            }
        }
    }

    function _indexAgreesWithFunctions(address tokenContract, uint256 tokenId) internal view returns (bool) {
        Indexed storage entry = _index[tokenContract][tokenId];
        ICompositionToken t = ICompositionToken(tokenContract);
        (address account, bytes4 accountType, bytes memory accountData) = t.compositionAccountOf(tokenId);
        bytes memory composition = entry.declared ? abi.encode(t.compositionOf(tokenId)) : bytes("");
        if (!entry.declared && t.compositionOf(tokenId).length != 0) return false;
        return entry.account == account && entry.accountType == accountType
            && keccak256(entry.accountData) == keccak256(accountData)
            && keccak256(entry.composition) == keccak256(composition) && entry.burner == t.burnedBy(tokenId);
    }

    // ------------------------------------------------------------ lock (group C)

    /// @dev Alice holds the token, Bob is her operator for all tokens, Carol is approved for
    ///      this one. Everyone, the token contract and a holder contract included, tries every
    ///      exit the container offers: nothing leaves, no allowance is granted.
    function _checkNothingLeavesBeforeBurn(uint256 tokenId) internal returns (bool) {
        address owner = token.ownerOf(tokenId);
        vm.prank(owner);
        token.setApprovalForAll(bob, true);
        vm.prank(owner);
        token.approve(carol, tokenId);

        address account = _containerOf(tokenId);
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        uint256[] memory before = _balances(tokenId);
        address[6] memory callers = [owner, bob, carol, address(token), address(new Holder()), stranger];
        for (uint256 k; k < callers.length; ++k) {
            for (uint256 i; i < c.length; ++i) {
                if (_tryExit(callers[k], account, c[i].asset, callers[k], 1)) return false;
                if (c[i].asset != NATIVE) {
                    if (_tryApprove(callers[k], account, c[i].asset, callers[k])) return false;
                    if (IERC20(c[i].asset).allowance(account, callers[k]) != 0) return false;
                }
            }
        }
        uint256[] memory afterAll = _balances(tokenId);
        return keccak256(abi.encode(before)) == keccak256(abi.encode(afterAll));
    }

    /// @dev ERC-6551 only: neither magic value while the token exists.
    function _checkNoSignerOrSignatureBeforeBurn(uint256 tokenId) internal view returns (bool) {
        address account = _containerOf(tokenId);
        IERC6551Account a = IERC6551Account(payable(account));
        address[6] memory candidates = [alice, bob, carol, address(token), account, address(0)];
        for (uint256 i; i < candidates.length; ++i) {
            if (a.isValidSigner(candidates[i], "") == ERC6551_SIGNER_MAGIC) return false;
        }
        bytes32 hash = keccak256("an authorization");
        uint256[3] memory keys = [aliceKey, bobKey, carolKey];
        for (uint256 i; i < keys.length; ++i) {
            if (IERC1271(account).isValidSignature(hash, _sign(keys[i], hash)) == ERC1271_MAGIC) return false;
        }
        if (IERC1271(account).isValidSignature(hash, "") == ERC1271_MAGIC) return false;
        if (
            IERC1271(account).isValidSignature(hash, abi.encodePacked(keccak256("noise"), keccak256("more"), uint8(27)))
                == ERC1271_MAGIC
        ) {
            return false;
        }
        return true;
    }

    /// @dev A constituent that accepts ERC-1271 authorizations: one signed by the holder on
    ///      behalf of the container is refused before the burn, and nothing moves.
    function _checkErc1271ConsumerBeforeBurn() internal returns (bool) {
        SignatureTransferERC20 sig = new SignatureTransferERC20();
        sig.mint(alice, 100e18);
        vm.prank(alice);
        sig.approve(address(token), type(uint256).max);
        uint256 tokenId = _mint(alice, alice, _one(address(sig), 10e18));
        address account = _containerOf(tokenId);
        bytes memory signature = _sign(aliceKey, sig.authorizationDigest(account, alice, 10e18, 1));
        vm.prank(stranger);
        try sig.transferWithSignature(account, alice, 10e18, 1, signature) {
            return false;
        } catch {}
        return sig.balanceOf(account) == 10e18;
    }

    /// @dev On another chain id, after the burn: no signer, no signature, no exit.
    function _checkOtherChainNothingValidates(uint256 tokenId) internal returns (bool) {
        address account = _containerOf(tokenId);
        address asset = token.compositionOf(tokenId)[0].asset;
        address owner = token.ownerOf(tokenId);
        vm.prank(owner);
        token.burn(tokenId);
        uint256 chainId = vm.getChainId();
        vm.chainId(chainId + 1);
        bool ok = true;
        if (_isERC6551()) {
            if (IERC6551Account(payable(account)).isValidSigner(owner, "") == ERC6551_SIGNER_MAGIC) ok = false;
        }
        if (_tryExit(owner, account, asset, owner, 1)) ok = false;
        vm.chainId(chainId);
        return ok;
    }

    /// @dev After the burn, minting the same id again through the internal path fails.
    function _checkRemintRejected(address harness) internal returns (bool) {
        ICompositionToken h = ICompositionToken(harness);
        vm.prank(alice);
        uint256 tokenId = h.mint{value: 1 ether}(alice, _one(NATIVE, 1 ether));
        vm.prank(alice);
        h.burn(tokenId);
        try IForceMint(harness).forceMint(bob, tokenId) {
            return false;
        } catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.BurnedTokenRemint.selector)) return false;
        }
        return h.burnedBy(tokenId) == alice;
    }

    function _checkOwnContainerRejected(uint256 tokenId) internal returns (bool) {
        address account = _containerOf(tokenId);
        address owner = token.ownerOf(tokenId);
        vm.prank(owner);
        try token.transferFrom(owner, account, tokenId) {
            return false;
        } catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        vm.prank(owner);
        try token.safeTransferFrom(owner, account, tokenId) {
            return false;
        } catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        return token.ownerOf(tokenId) == owner;
    }

    function _checkOtherContainerRejected() internal returns (bool) {
        uint256 a = _mintThree(alice);
        uint256 b = _mintThree(alice);
        address containerOfB = _containerOf(b);
        vm.prank(alice);
        try token.transferFrom(alice, containerOfB, a) {
            return false;
        } catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        return token.ownerOf(a) == alice;
    }

    /// @dev Two pieces can never end up each in the other's container, in either mint order.
    function _checkTwoPieceCycleCannotClose() internal returns (bool) {
        uint256 a = _mintThree(alice);
        uint256 b = _mintThree(alice);
        address ca = _containerOf(a);
        address cb = _containerOf(b);
        vm.prank(alice);
        try token.transferFrom(alice, cb, a) {}
        catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        vm.prank(alice);
        try token.transferFrom(alice, ca, b) {}
        catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        if (token.ownerOf(a) == cb && token.ownerOf(b) == ca) return false;

        // a piece sent ahead to the container of the next piece, before that piece exists
        uint256 first = _mintThree(alice);
        address future = _predictedContainer(address(token), first + 1);
        vm.prank(alice);
        token.transferFrom(alice, future, first);
        uint256 second = _mintThree(alice);
        if (second != first + 1 || token.ownerOf(first) != _containerOf(second)) return false;
        address containerOfFirst = _containerOf(first);
        vm.prank(alice);
        try token.transferFrom(alice, containerOfFirst, second) {}
        catch (bytes memory reason) {
            if (!_hasSelector(reason, ERC721Composition.TransferToDeclaredContainer.selector)) return false;
        }
        return token.ownerOf(second) != containerOfFirst;
    }

    /// @dev Each of three pieces sent ahead into the container of the next one, before that
    ///      piece exists: the youngest can go into neither older container, with the exact error.
    function _checkChainOfThreeNeverCloses() internal returns (bool) {
        uint256 a = _mintThree(alice);
        address aheadOfA = _predictedContainer(address(token), a + 1);
        vm.prank(alice);
        token.transferFrom(alice, aheadOfA, a);
        uint256 b = _mintThree(alice);
        address aheadOfB = _predictedContainer(address(token), b + 1);
        vm.prank(alice);
        token.transferFrom(alice, aheadOfB, b);
        uint256 c = _mintThree(alice);
        if (token.ownerOf(a) != _containerOf(b) || token.ownerOf(b) != _containerOf(c)) return false;
        uint256[2] memory older = [a, b];
        for (uint256 i; i < older.length; ++i) {
            address containerOfOlder = _containerOf(older[i]);
            vm.prank(alice);
            try token.transferFrom(alice, containerOfOlder, c) {
                return false;
            } catch (bytes memory reason) {
                bytes memory expected =
                    abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, c, older[i]);
                if (keccak256(reason) != keccak256(expected)) return false;
            }
        }
        return token.ownerOf(c) == alice;
    }

    function _checkContainersDistinct(uint256[] memory ids) internal view returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                if (_containerOf(ids[i]) == _containerOf(ids[j])) return false;
            }
        }
        return true;
    }
}
