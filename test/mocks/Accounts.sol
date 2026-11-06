// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";
import {IERC6551Account, IERC6551Executable} from "../../src/interfaces/IERC6551.sol";

/// @dev Reads the token bound to an ERC-6551 account from the footer of its proxy code.
abstract contract AccountFooter {
    function _footer() internal view returns (uint256, address, uint256) {
        bytes memory footer = new bytes(0x60);
        assembly ("memory-safe") {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }
}

/// @dev The example account from the ERC-6551 text (CC0), unchanged in substance: the holder
///      of the token can move the assets at any time. A reader must tell it apart from a locked
///      account.
contract ExampleERC6551Account is AccountFooter, IERC165, IERC1271, IERC6551Account, IERC6551Executable {
    uint256 public state;

    receive() external payable {}

    function token() public view returns (uint256, address, uint256) {
        return _footer();
    }

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        require(_isValidSigner(msg.sender), "Invalid signer");
        require(operation == 0, "Only call operations are supported");
        ++state;
        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        if (_isValidSigner(signer)) return IERC6551Account.isValidSigner.selector;
        return bytes4(0);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (SignatureChecker.isValidSignatureNow(owner(), hash, signature)) return IERC1271.isValidSignature.selector;
        return bytes4(0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId;
    }

    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function _isValidSigner(address signer) internal view returns (bool) {
        return signer == owner();
    }
}

/// @dev Shared logic of the two defective locked accounts below: execution and signer checks
///      follow `burnedBy`, as in the reference account.
abstract contract BurnerGatedAccount is AccountFooter, IERC165, IERC1271, IERC6551Account, IERC6551Executable {
    uint256 public state;

    receive() external payable {}

    function token() public view returns (uint256, address, uint256) {
        return _footer();
    }

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        require(_burner() != address(0) && msg.sender == _burner(), "Invalid signer");
        require(operation == 0, "Only call operations are supported");
        ++state;
        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        address burner = _burner();
        return burner != address(0) && signer == burner ? IERC6551Account.isValidSigner.selector : bytes4(0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId || interfaceId == type(IERC1271).interfaceId;
    }

    function _burner() internal view virtual returns (address);

    function _burnedBy(address tokenContract, uint256 tokenId) internal view returns (address) {
        (bool ok, bytes memory ret) = tokenContract.staticcall(abi.encodeCall(IERC721BurnRecord.burnedBy, (tokenId)));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }
}

/// @dev Defect X1: `isValidSigner` is locked, but `isValidSignature` validates the token
///      holder's signatures, as the example account of the ERC-6551 text does. Any contract
///      that accepts ERC-1271 authorizations lets the holder empty the account while the token
///      exists, without ever calling `execute`.
contract LeakySignatureAccount is BurnerGatedAccount {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return bytes4(0xffffffff);
        address holder = IERC721(tokenContract).ownerOf(tokenId);
        if (SignatureChecker.isValidSignatureNow(holder, hash, signature)) return IERC1271.isValidSignature.selector;
        return bytes4(0xffffffff);
    }

    function _burner() internal view override returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        return _burnedBy(tokenContract, tokenId);
    }
}

/// @dev Defect X13: no check of the chain id, so after the burn the burner can act for the
///      same address on any other chain where the account exists.
contract ChainBlindAccount is BurnerGatedAccount {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address burner = _burner();
        if (burner != address(0) && SignatureChecker.isValidSignatureNow(burner, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }

    function _burner() internal view override returns (address) {
        (, address tokenContract, uint256 tokenId) = token();
        return _burnedBy(tokenContract, tokenId);
    }
}

/// @dev An implementation that is itself an upgradeable proxy (ERC-1967): the registry's proxy
///      delegates to it, and it delegates onward to the implementation written in the account's
///      own storage, or to `initialImplementation` while none is written. `admin` can rewrite
///      it at any time. Address and verification data stay the same across an upgrade, and no
///      contract can read another contract's storage to notice. Generic, written for the tests.
contract UpgradeableAccountProxy is Proxy {
    address public immutable admin;
    address public immutable initialImplementation;

    constructor(address admin_, address initialImplementation_) {
        admin = admin_;
        initialImplementation = initialImplementation_;
    }

    receive() external payable {
        _fallback();
    }

    function upgradeTo(address newImplementation) external {
        require(msg.sender == admin, "not admin");
        ERC1967Utils.upgradeToAndCall(newImplementation, "");
    }

    function _implementation() internal view override returns (address implementation) {
        implementation = ERC1967Utils.getImplementation();
        if (implementation == address(0)) implementation = initialImplementation;
    }
}

/// @dev The same pattern for a token contract: a token behind an ERC-1967 proxy keeps its address
///      and the code at that address across an upgrade, while the logic that answers `burnedBy`
///      changes. Generic, written for the tests.
contract UpgradeableTokenProxy is Proxy {
    address public immutable admin;
    address public immutable initialImplementation;

    constructor(address admin_, address initialImplementation_) {
        admin = admin_;
        initialImplementation = initialImplementation_;
    }

    receive() external payable {
        _fallback();
    }

    function upgradeTo(address newImplementation) external {
        require(msg.sender == admin, "not admin");
        ERC1967Utils.upgradeToAndCall(newImplementation, "");
    }

    function _implementation() internal view override returns (address implementation) {
        implementation = ERC1967Utils.getImplementation();
        if (implementation == address(0)) implementation = initialImplementation;
    }
}
