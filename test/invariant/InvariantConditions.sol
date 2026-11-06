// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Variant} from "../utils/Variant.sol";
import {CompositionHandler} from "./CompositionHandler.sol";

/// @dev The conditions of group G, written once. Each returns an empty string when it holds,
///      or the first violation found. The invariants require the empty string after every step
///      of a random sequence; the defect tests run a fixed sequence on a defective contract and
///      require the violation, so both use the same condition.
abstract contract InvariantConditions is Variant {
    CompositionHandler internal handler;

    /// G1 · P1, FT4. Live pieces and pieces not yet minted: every container holds exactly what
    ///    the model says, and every live piece is where the model put it, also inside a
    ///    container.
    function _conditionNothingLeavesBeforeBurn() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 k = 1; k <= handler.MAX_PIECES(); ++k) {
            if (k <= n && handler.burned(k)) continue;
            string memory balances = _balancesMatchModel(k);
            if (bytes(balances).length != 0) return balances;
        }
        for (uint256 id = 1; id <= n; ++id) {
            if (!handler.burned(id) && token.ownerOf(id) != handler.modelOwner(id)) return _say("piece moved", id);
        }
        if (handler.unexpectedExits() != 0) return "something left a container";
        return "";
    }

    /// G2 · P1, BR2, BR5. Burned pieces: the container holds what the model says, which only
    ///    the burner's withdrawals have reduced; every other attempt failed.
    function _conditionOnlyBurnerWithdraws() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 k = 1; k <= n; ++k) {
            if (!handler.burned(k)) continue;
            string memory balances = _balancesMatchModel(k);
            if (bytes(balances).length != 0) return balances;
        }
        if (handler.unexpectedExits() != 0) return "someone other than the burner took something out";
        return "";
    }

    /// G3 · P4, P8. Minted ids, live or burned, answer what the model recorded at mint; ids
    ///    never minted answer empty values.
    function _conditionDeclarationsNeverChange() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 id; id <= handler.MAX_PIECES() + 1; ++id) {
            if (id != 0 && id <= n) {
                if (_functionsHash(id) != handler.declarationHash(id)) {
                    return _say("functions differ from the model", id);
                }
                continue;
            }
            (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(id);
            if (
                token.compositionOf(id).length != 0 || account != address(0) || accountType != bytes4(0)
                    || accountData.length != 0
            ) return _say("values for an id never minted", id);
        }
        return "";
    }

    /// G4 · P6, FT1-FT3. The index rebuilt from the logs alone and the functions
    ///    both match the model, not only each other.
    function _conditionFunctionsAndEventsMatchModel() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 id = 1; id <= n; ++id) {
            if (handler.eventCount(id) != 1) return _say("not exactly one event", id);
            if (handler.indexHash(id) != handler.declarationHash(id)) return _say("index differs from the model", id);
            if (_functionsHash(id) != handler.declarationHash(id)) return _say("functions differ from the model", id);
        }
        if (handler.eventsOutsideMint() != 0) return "declaration event outside the mint";
        return "";
    }

    /// G5 · P12. Every piece held by another piece's container is older than that
    ///    piece; following owners from any piece never comes back to it.
    function _conditionInsideImpliesOlder() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 id = 1; id <= n; ++id) {
            if (handler.burned(id)) continue;
            uint256 current = id;
            for (uint256 step; step <= n; ++step) {
                uint256 k = handler.pieceOfContainer(token.ownerOf(current));
                if (k == 0) break;
                if (k == id) return _say("ownership cycle through piece", id);
                if (current >= k) return _say("a piece inside the container of an older piece", current);
                if (k > n || handler.burned(k)) break;
                current = k;
            }
        }
        if (handler.acceptedButShouldFail("container") != 0) return "accepted into a declared container";
        if (handler.failedWithWrongError("container") != 0) return "container: rejected with the wrong error";
        return "";
    }

    /// G6 · P7, BR4. A burned id stays nonexistent and keeps the burner of its only burn.
    function _conditionNoBurnedIdReappears() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 id = 1; id <= n; ++id) {
            if (handler.burned(id)) {
                (bool exists,) = address(token).staticcall(abi.encodeCall(IERC721.ownerOf, (id)));
                if (exists) return _say("a burned id exists again", id);
                if (token.burnedBy(id) != handler.burnerOf(id)) return _say("burner changed", id);
            } else if (token.burnedBy(id) != address(0)) {
                return _say("burner for a live piece", id);
            }
        }
        if (handler.acceptedButShouldFail("remint") != 0) return "remint accepted";
        if (handler.failedWithWrongError("remint") != 0) return "remint: rejected with the wrong error";
        if (handler.acceptedButShouldFail("burn") != 0) return "burn by someone not approved";
        if (handler.failedWithWrongError("burn") != 0) return "burn: rejected with the wrong error";
        return "";
    }

    /// G7 · P5. For every live piece and every constituent, the container holds at least the
    ///    declared amount.
    function _conditionLowerBoundForOrdinaryConstituents() internal view returns (string memory) {
        uint256 n = handler.minted();
        for (uint256 id = 1; id <= n; ++id) {
            if (handler.burned(id)) continue;
            address container = handler.containerOf(id);
            for (uint256 i; i < 3; ++i) {
                address asset = handler.assets(i);
                if (_balance(asset, container) < handler.declared(id, asset)) {
                    return _say("below the declared amount", id);
                }
            }
        }
        return "";
    }

    // ------------------------------------------------------------ helpers

    function _functionsHash(uint256 id) internal view returns (bytes32) {
        (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(id);
        return keccak256(abi.encode(token.compositionOf(id), account, accountType, accountData));
    }

    function _balancesMatchModel(uint256 k) internal view returns (string memory) {
        address container = handler.containerOf(k);
        for (uint256 i; i < 3; ++i) {
            address asset = handler.assets(i);
            if (_balance(asset, container) != handler.expectedBalance(container, asset)) {
                return _say("balance differs from the model, container of piece", k);
            }
        }
        return "";
    }

    function _say(string memory what, uint256 id) internal pure returns (string memory) {
        return string.concat(what, " ", vm.toString(id));
    }
}
