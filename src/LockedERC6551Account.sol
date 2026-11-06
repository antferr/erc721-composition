// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";
import {IERC6551Account, IERC6551Executable} from "./interfaces/IERC6551.sol";

/// @title ERC-6551 account that stays locked until its token is burned
/// @notice Adapted from the example account in the ERC-6551 text (CC0). While the token
///         exists nobody is a valid signer: not the holder, not an approved operator, not
///         the token contract. After the burn the only valid signer is the address that
///         `burnedBy` returns. On a chain other than the token's, nobody is.
/// @dev Deployed once and used through the canonical ERC-6551 registry, which creates one
///      ERC-1167 proxy per token. No upgrade, module or other authorization path exists,
///      and only CALL operations are executed.
contract LockedERC6551Account is IERC165, IERC1271, IERC6551Account, IERC6551Executable {
    uint256 public state;

    error InvalidSigner();
    error OnlyCallOperations();

    receive() external payable {}

    /// @inheritdoc IERC6551Executable
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        if (!_isValidSigner(msg.sender)) revert InvalidSigner();
        if (operation != 0) revert OnlyCallOperations();

        ++state;

        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @inheritdoc IERC6551Account
    /// @dev Never the magic value while the token exists; after the burn, only for the burner.
    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        return _isValidSigner(signer) ? IERC6551Account.isValidSigner.selector : bytes4(0);
    }

    /// @inheritdoc IERC1271
    /// @dev Never the magic value while the token exists; after the burn, only for a valid
    ///      signature of the burner.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address burner = _burner();
        if (burner != address(0) && SignatureChecker.isValidSignatureNow(burner, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId || interfaceId == type(IERC1271).interfaceId;
    }

    /// @inheritdoc IERC6551Account
    function token() public view returns (uint256, address, uint256) {
        bytes memory footer = new bytes(0x60);
        assembly ("memory-safe") {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    /// @dev The burner recorded by the token contract, or zero: while the token exists, if
    ///      it was never minted, on another chain, or if the call fails or returns
    ///      malformed data. Zero means that nobody can act for the account.
    function _burner() internal view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        (bool ok, bytes memory ret) = tokenContract.staticcall(abi.encodeCall(IERC721BurnRecord.burnedBy, (tokenId)));
        if (!ok || ret.length != 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    function _isValidSigner(address signer) internal view returns (bool) {
        address burner = _burner();
        return burner != address(0) && signer == burner;
    }
}
