// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";

/// @title Interface of a minimal custom container, used as the second container type
/// @dev Defined for this repository: it shows that the composition interface does not
///      depend on ERC-6551. Its ERC-165 identifier is the container type.
interface ILockedContainer {
    /// @notice The token this container belongs to. Constant.
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);

    /// @notice Moves assets out. Reverts unless the token is burned and the caller is the burner.
    function withdraw(address asset, address to, uint256 amount) external;
}

/// @title Minimal container dedicated to one token, locked until the token is burned
/// @dev The runtime code is the same for every token, because the binding is kept in
///      storage and written once by the constructor: a reader recognizes the code by its
///      hash and reads the binding with `token()`. No upgrade or other authorization path.
contract LockedContainer is IERC165, ILockedContainer {
    using SafeERC20 for IERC20;

    address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 private _chainId;
    address private _tokenContract;
    uint256 private _tokenId;

    error NotBurner();
    error NativeTransferFailed();

    constructor(address tokenContract_, uint256 tokenId_) {
        _chainId = block.chainid;
        _tokenContract = tokenContract_;
        _tokenId = tokenId_;
    }

    receive() external payable {}

    /// @inheritdoc ILockedContainer
    function token() external view returns (uint256, address, uint256) {
        return (_chainId, _tokenContract, _tokenId);
    }

    /// @inheritdoc ILockedContainer
    function withdraw(address asset, address to, uint256 amount) external {
        if (block.chainid != _chainId) revert NotBurner();
        address burner = IERC721BurnRecord(_tokenContract).burnedBy(_tokenId);
        if (burner == address(0) || msg.sender != burner) revert NotBurner();
        if (asset == NATIVE_ASSET) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(ILockedContainer).interfaceId;
    }
}
