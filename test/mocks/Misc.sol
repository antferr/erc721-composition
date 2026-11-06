// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";

/// @dev Plain ERC-721 with ERC-165 and no composition: a reader must say "not supported".
contract PlainERC721 is ERC721 {
    constructor() ERC721("Plain", "PLN") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev Emits the composition event alone, to measure its share of the cost of a mint.
contract EventEmitter {
    function emitOne(address account, bytes memory accountData, address asset, uint256 amount) external {
        IERC721Composition.Constituent[] memory c = new IERC721Composition.Constituent[](1);
        c[0] = IERC721Composition.Constituent(asset, amount);
        emit IERC721Composition.CompositionDeclared(1, account, 0x6faff5f1, accountData, c);
    }

    function emitThree(address account, bytes memory accountData, IERC721Composition.Constituent[] memory c) external {
        emit IERC721Composition.CompositionDeclared(1, account, 0x6faff5f1, accountData, c);
    }

    function noop(address, bytes memory, address, uint256) external {}

    function noopThree(address, bytes memory, IERC721Composition.Constituent[] memory) external {}
}

/// @dev Measures a call one level down, where it is an ordinary internal call and not a
///      transaction of its own: no base cost and no calldata floor (EIP-7623), which would
///      otherwise raise the cost of a cheap call and hide part of the difference between two.
contract GasMeter {
    function measure(address target, bytes calldata data) external returns (uint256 used) {
        uint256 start = gasleft();
        (bool ok,) = target.call(data);
        used = start - gasleft();
        require(ok, "measured call failed");
    }
}

/// @dev Declares the composition interface and answers in a hostile way, for the reader.
contract HostileCompositionContract is IERC165 {
    enum Mode {
        HugeAnswer,
        BurnGas,
        MalformedComposition,
        MalformedAccount
    }

    Mode public immutable mode;

    constructor(Mode mode_) {
        mode = mode_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xd60a6c7e || interfaceId == 0x43470a89;
    }

    function burnedBy(uint256) external pure returns (address) {
        return address(0);
    }

    function compositionOf(uint256) external view returns (IERC721Composition.Constituent[] memory) {
        if (mode == Mode.HugeAnswer) {
            assembly ("memory-safe") {
                // 64 KiB of zeros: cheap for this contract to return, costly for a caller to copy
                return(0, 0x10000)
            }
        }
        if (mode == Mode.BurnGas) {
            uint256 i;
            while (true) {
                ++i;
            }
        }
        if (mode == Mode.MalformedComposition) {
            assembly ("memory-safe") {
                // an offset that points past the end of the answer
                mstore(0, 0xffff)
                return(0, 0x20)
            }
        }
        IERC721Composition.Constituent[] memory c = new IERC721Composition.Constituent[](1);
        c[0] = IERC721Composition.Constituent(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, 1);
        return c;
    }

    function compositionAccountOf(uint256) external pure returns (address, bytes4, bytes memory) {
        assembly ("memory-safe") {
            // a single word: too short for (address, bytes4, bytes)
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}
