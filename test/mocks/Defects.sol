// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721BurnRecord} from "erc721-burn-record/ERC721BurnRecord.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {ERC721Composition} from "../../src/ERC721Composition.sol";
import {CompositionToken} from "../../src/CompositionToken.sol";
import {CustomContainerCompositionToken} from "../../src/CustomContainerCompositionToken.sol";
import {ConsecutiveCompositionToken} from "../../src/ConsecutiveCompositionToken.sol";
import {IERC6551Registry} from "../../src/interfaces/IERC6551.sol";

// ------------------------------------------------------------------ harnesses

/// @dev Reference token plus a direct path to the internal mint, to show that the extension
///      refuses re-minting a burned id and minting an undeclared id whatever path is used.
contract CompositionTokenHarness is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function forceMint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev Same as {CompositionTokenHarness}, for the custom container variant.
contract CustomContainerTokenHarness is CustomContainerCompositionToken {
    function forceMint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev A token contract with a backdoor in `burnedBy`: it names an address of its choice as
///      burner while the token still exists. The locked account obeys it, which is why a reader
///      must recognize the token contract as well as the container.
contract BackdooredCompositionToken is CompositionToken {
    address public immutable backdoor;

    constructor(address accountImplementation, address backdoor_) CompositionToken(accountImplementation) {
        backdoor = backdoor_;
    }

    function burnedBy(uint256 tokenId) public view override returns (address) {
        if (_ownerOf(tokenId) != address(0)) return backdoor;
        return super.burnedBy(tokenId);
    }
}

/// @dev Declares as its own the container that another contract declared for its token: the
///      binding does not match, whatever the reader thinks of this contract's code.
contract ForeignContainerToken is CompositionToken {
    address public immutable foreignToken;
    uint256 public immutable foreignId;

    constructor(address accountImplementation, address foreignToken_, uint256 foreignId_)
        CompositionToken(accountImplementation)
    {
        foreignToken = foreignToken_;
        foreignId = foreignId_;
    }

    function compositionAccountOf(uint256 tokenId)
        public
        view
        override
        returns (address account, bytes4 accountType, bytes memory accountData)
    {
        (account, accountType, accountData) = super.compositionAccountOf(tokenId);
        if (account != address(0)) {
            (account,,) = IERC721Composition(foreignToken).compositionAccountOf(foreignId);
        }
    }
}

// ------------------------------------------------------------------ defects X2-X12

/// @dev Defect X2: a burned id can be minted again. With ERC-6551 the new token finds the same
///      container, still holding whatever the previous burner left in it.
contract RemintableCompositionToken is CompositionTokenHarness {
    constructor(address accountImplementation) CompositionTokenHarness(accountImplementation) {}

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(tokenId) == address(0) && burnedBy(tokenId) != address(0)) {
            // skips the composition checks, keeps the burn record
            return ERC721BurnRecord._update(to, tokenId, auth);
        }
        return super._update(to, tokenId, auth);
    }
}

/// @dev Defect X3: the declaration changes after the mint, here as a "sync" that halves the
///      declared amounts once the token has changed hands.
contract MutableCompositionToken is CompositionToken {
    mapping(uint256 tokenId => bool) internal _moved;

    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function compositionOf(uint256 tokenId) public view override returns (Constituent[] memory constituents) {
        constituents = super.compositionOf(tokenId);
        if (_moved[tokenId]) {
            for (uint256 i; i < constituents.length; ++i) {
                constituents[i].amount /= 2;
            }
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) _moved[tokenId] = true;
    }
}

/// @dev Defect X4: the function answers differently from the event.
contract MismatchedEventToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function compositionOf(uint256 tokenId) public view override returns (Constituent[] memory constituents) {
        constituents = super.compositionOf(tokenId);
        for (uint256 i; i < constituents.length; ++i) {
            constituents[i].amount += 1;
        }
    }
}

/// @dev Defect X5: the same wrong container in state and event. The container created and
///      declared for `tokenId` is the registry account of `tokenId + 1000`: functions and event
///      agree with each other, and both are wrong.
contract ConsistentlyWrongToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function _createContainer(uint256 tokenId) internal override returns (address) {
        return ERC6551_REGISTRY.createAccount(
            ACCOUNT_IMPLEMENTATION, ACCOUNT_SALT, block.chainid, address(this), tokenId + 1000
        );
    }
}

/// @dev Defect X6: a batch mint that declares, and so announces, only the first id.
contract SilentBatchToken is ConsecutiveCompositionToken {
    constructor(address accountImplementation, address receiver, uint96 batchSize, uint256 nativePerToken)
        payable
        ConsecutiveCompositionToken(accountImplementation, receiver, batchSize, nativePerToken)
    {}

    function _declareComposition(uint256 tokenId, address account, Constituent[] memory constituents)
        internal
        override
    {
        if (tokenId == 0) super._declareComposition(tokenId, account, constituents);
    }
}

/// @dev Defect X7: the functions revert for an id that was never minted.
contract RevertingViewToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function compositionOf(uint256 tokenId) public view override returns (Constituent[] memory) {
        require(_ownerOf(tokenId) != address(0) || burnedBy(tokenId) != address(0), "unknown token");
        return super.compositionOf(tokenId);
    }

    function compositionAccountOf(uint256 tokenId) public view override returns (address, bytes4, bytes memory) {
        require(_ownerOf(tokenId) != address(0) || burnedBy(tokenId) != address(0), "unknown token");
        return super.compositionAccountOf(tokenId);
    }
}

/// @dev Defect X8: transfers skip the container check altogether.
contract NoOwnContainerCheckToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(tokenId) != address(0)) {
            return ERC721BurnRecord._update(to, tokenId, auth);
        }
        return super._update(to, tokenId, auth);
    }
}

/// @dev Defect X9: transfers are checked only against the token's own container, as an
///      earlier version of this code did.
contract OwnContainerOnlyToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(tokenId) != address(0)) {
            (address own,,) = compositionAccountOf(tokenId);
            if (to == own) revert TransferToDeclaredContainer(tokenId, tokenId);
            return ERC721BurnRecord._update(to, tokenId, auth);
        }
        return super._update(to, tokenId, auth);
    }
}

/// @dev Defect X11: every token reports the container of token 1.
contract SharedContainerToken is CompositionToken {
    constructor(address accountImplementation) CompositionToken(accountImplementation) {}

    function compositionAccountOf(uint256 tokenId)
        public
        view
        override
        returns (address account, bytes4 accountType, bytes memory accountData)
    {
        (account, accountType, accountData) = super.compositionAccountOf(tokenId);
        if (account != address(0)) (account,,) = super.compositionAccountOf(1);
    }
}

/// @dev Minimal token for the defects that the reference extension makes impossible to obtain
///      by overriding: it keeps its own records and emits the event itself.
abstract contract MinimalCompositionToken is ERC721, ERC721Burnable, ERC721BurnRecord, IERC721Composition {
    using SafeERC20 for IERC20;

    IERC6551Registry public constant ERC6551_REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable ACCOUNT_IMPLEMENTATION;
    uint256 internal _next = 1;
    mapping(uint256 => Constituent[]) internal _compositions;
    mapping(uint256 => address) internal _accounts;

    constructor(address accountImplementation) ERC721("Minimal", "MIN") {
        ACCOUNT_IMPLEMENTATION = accountImplementation;
    }

    function mint(address to, Constituent[] calldata constituents) external payable returns (uint256 tokenId) {
        tokenId = _next++;
        address account = _container(tokenId);
        for (uint256 i; i < constituents.length; ++i) {
            _compositions[tokenId].push(constituents[i]);
        }
        _accounts[tokenId] = account;
        emit CompositionDeclared(
            tokenId, account, 0x6faff5f1, abi.encode(ACCOUNT_IMPLEMENTATION, bytes32(0)), constituents
        );
        for (uint256 i; i < constituents.length; ++i) {
            if (constituents[i].asset == NATIVE_ASSET) {
                (bool ok,) = account.call{value: constituents[i].amount}("");
                require(ok, "native transfer failed");
            } else {
                IERC20(constituents[i].asset).safeTransferFrom(msg.sender, account, constituents[i].amount);
            }
        }
        _safeMint(to, tokenId);
    }

    function compositionOf(uint256 tokenId) external view returns (Constituent[] memory) {
        return _compositions[tokenId];
    }

    function compositionAccountOf(uint256 tokenId) external view returns (address, bytes4, bytes memory) {
        address account = _accounts[tokenId];
        if (account == address(0)) return (address(0), bytes4(0), "");
        return (account, 0x6faff5f1, abi.encode(ACCOUNT_IMPLEMENTATION, bytes32(0)));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721BurnRecord) returns (bool) {
        return interfaceId == type(IERC721Composition).interfaceId || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721BurnRecord)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _container(uint256 tokenId) internal virtual returns (address);
}

/// @dev Defect X10: the container is declared at the address the registry will use, but never
///      created: at the end of the mint nobody can ask it anything.
contract LazyContainerToken is MinimalCompositionToken {
    constructor(address accountImplementation) MinimalCompositionToken(accountImplementation) {}

    function _container(uint256 tokenId) internal view override returns (address) {
        return ERC6551_REGISTRY.account(ACCOUNT_IMPLEMENTATION, bytes32(0), block.chainid, address(this), tokenId);
    }
}

/// @dev Defect X12: the mint declares what it was asked to declare, without measuring what the
///      container actually received.
contract UnmeasuredMintToken is MinimalCompositionToken {
    constructor(address accountImplementation) MinimalCompositionToken(accountImplementation) {}

    function _container(uint256 tokenId) internal override returns (address) {
        return ERC6551_REGISTRY.createAccount(ACCOUNT_IMPLEMENTATION, bytes32(0), block.chainid, address(this), tokenId);
    }
}

/// @dev Custom container variant of {ForeignContainerToken}: declares the container of a token
///      of another contract.
contract ForeignCustomContainerToken is CustomContainerCompositionToken {
    address public immutable foreignToken;
    uint256 public immutable foreignId;

    constructor(address foreignToken_, uint256 foreignId_) {
        foreignToken = foreignToken_;
        foreignId = foreignId_;
    }

    function compositionAccountOf(uint256 tokenId)
        public
        view
        override
        returns (address account, bytes4 accountType, bytes memory accountData)
    {
        (account, accountType, accountData) = super.compositionAccountOf(tokenId);
        if (account != address(0)) {
            (account,,) = IERC721Composition(foreignToken).compositionAccountOf(foreignId);
        }
    }
}
