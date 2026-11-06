// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {CompositionToken} from "../../src/CompositionToken.sol";
import {CustomContainerCompositionToken} from "../../src/CustomContainerCompositionToken.sol";
import {LockedContainer, ILockedContainer} from "../../src/LockedContainer.sol";
import {IERC6551Executable, IERC6551Registry} from "../../src/interfaces/IERC6551.sol";
import {CompositionTokenHarness, CustomContainerTokenHarness} from "../mocks/Defects.sol";
import {Base} from "../Base.t.sol";

/// @dev What the tests need from any composition token: ERC-721, both extensions, the
///      reference mint and the burn.
interface ICompositionToken is IERC721, IERC721Composition, IERC721BurnRecord {
    function mint(address to, IERC721Composition.Constituent[] calldata constituents)
        external
        payable
        returns (uint256 tokenId);

    function burn(uint256 tokenId) external;
}

interface IForceMint {
    function forceMint(address to, uint256 tokenId) external;
}

interface IAccountImplementation {
    function ACCOUNT_IMPLEMENTATION() external view returns (address);
}

/// @dev The hooks that make the same test run on both container types.
abstract contract Variant is Base {
    ICompositionToken internal token;

    function setUp() public virtual override {
        super.setUp();
        _useToken(_deployToken());
    }

    /// @dev Points the tests at `tokenContract` and lets the three people fund mints with it.
    function _useToken(address tokenContract) internal {
        token = ICompositionToken(tokenContract);
        _approveAll(tokenContract);
    }

    function _approveAll(address spender) internal {
        address[3] memory people = [alice, bob, carol];
        for (uint256 i; i < people.length; ++i) {
            vm.startPrank(people[i]);
            tokenX.approve(spender, type(uint256).max);
            tokenY.approve(spender, type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ hooks

    function _deployToken() internal virtual returns (address);

    /// @dev A token of the same variant that also exposes the internal mint.
    function _deployHarness() internal virtual returns (address);

    /// @dev The address the container of `tokenId` of `tokenContract` has, or will have.
    function _predictedContainer(address tokenContract, uint256 tokenId) internal view virtual returns (address);

    function _expectedType() internal view virtual returns (bytes4);

    function _expectedData(address tokenContract) internal view virtual returns (bytes memory);

    /// @dev Tries to move `amount` of `asset` out of `container` to `to`, acting as `caller`,
    ///      through every exit the container type offers. True if anything succeeded.
    function _tryExit(address caller, address container, address asset, address to, uint256 amount)
        internal
        virtual
        returns (bool);

    /// @dev Tries to make the container grant `spender` an allowance on `asset`, acting as
    ///      `caller`. False for container types that have no such path.
    function _tryApprove(address caller, address container, address asset, address spender)
        internal
        virtual
        returns (bool);

    function _isERC6551() internal pure virtual returns (bool);

    // ------------------------------------------------------------ helpers

    function _mint(address minter, address to, IERC721Composition.Constituent[] memory c)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(minter);
        tokenId = token.mint{value: _nativeOf(c)}(to, c);
    }

    function _mintThree(address to) internal returns (uint256) {
        return _mint(alice, to, _three(1 ether, 10e18, 20e18));
    }

    function _containerOf(uint256 tokenId) internal view returns (address account) {
        (account,,) = token.compositionAccountOf(tokenId);
    }

    function _balance(address asset, address holder) internal view returns (uint256) {
        return asset == NATIVE ? holder.balance : IERC20(asset).balanceOf(holder);
    }

    /// @dev Balances of the container of `tokenId` for each declared constituent.
    function _balances(uint256 tokenId) internal view returns (uint256[] memory b) {
        IERC721Composition.Constituent[] memory c = token.compositionOf(tokenId);
        address account = _containerOf(tokenId);
        b = new uint256[](c.length);
        for (uint256 i; i < c.length; ++i) {
            b[i] = _balance(c[i].asset, account);
        }
    }

    function _encodedDeclaration(uint256 tokenId) internal view returns (bytes memory) {
        (address account, bytes4 accountType, bytes memory accountData) = token.compositionAccountOf(tokenId);
        return abi.encode(token.compositionOf(tokenId), account, accountType, accountData);
    }
}

/// @dev Variant 1: containers are ERC-6551 accounts created by the canonical registry.
abstract contract Variant6551 is Variant {
    function _deployToken() internal virtual override returns (address) {
        return address(new CompositionToken(address(implementation)));
    }

    function _deployHarness() internal virtual override returns (address) {
        return address(new CompositionTokenHarness(address(implementation)));
    }

    function _implementationOf(address tokenContract) internal view returns (address) {
        return IAccountImplementation(tokenContract).ACCOUNT_IMPLEMENTATION();
    }

    function _predictedContainer(address tokenContract, uint256 tokenId)
        internal
        view
        virtual
        override
        returns (address)
    {
        return IERC6551Registry(REGISTRY)
            .account(_implementationOf(tokenContract), bytes32(0), block.chainid, tokenContract, tokenId);
    }

    function _expectedType() internal pure override returns (bytes4) {
        return ERC6551_ACCOUNT_ID;
    }

    function _expectedData(address tokenContract) internal view override returns (bytes memory) {
        return abi.encode(_implementationOf(tokenContract), bytes32(0));
    }

    function _tryExit(address caller, address container, address asset, address to, uint256 amount)
        internal
        override
        returns (bool)
    {
        (address target, uint256 value, bytes memory data) = asset == NATIVE
            ? (to, amount, bytes(""))
            : (asset, uint256(0), abi.encodeCall(IERC20.transfer, (to, amount)));
        vm.prank(caller);
        try IERC6551Executable(payable(container)).execute(target, value, data, 0) {
            return true;
        } catch {
            return false;
        }
    }

    function _tryApprove(address caller, address container, address asset, address spender)
        internal
        override
        returns (bool)
    {
        vm.prank(caller);
        try IERC6551Executable(payable(container))
            .execute(asset, 0, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)), 0) {
            return true;
        } catch {
            return false;
        }
    }

    function _isERC6551() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Variant 2: containers are minimal custom contracts, one per token.
abstract contract VariantCustom is Variant {
    function _deployToken() internal virtual override returns (address) {
        return address(new CustomContainerCompositionToken());
    }

    function _deployHarness() internal virtual override returns (address) {
        return address(new CustomContainerTokenHarness());
    }

    function _predictedContainer(address tokenContract, uint256 tokenId)
        internal
        view
        virtual
        override
        returns (address)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(LockedContainer).creationCode, abi.encode(tokenContract, tokenId)));
        return vm.computeCreate2Address(bytes32(tokenId), initCodeHash, tokenContract);
    }

    function _expectedType() internal pure override returns (bytes4) {
        return type(ILockedContainer).interfaceId;
    }

    function _expectedData(address) internal pure override returns (bytes memory) {
        return "";
    }

    function _tryExit(address caller, address container, address asset, address to, uint256 amount)
        internal
        override
        returns (bool)
    {
        vm.prank(caller);
        try ILockedContainer(container).withdraw(asset, to, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _tryApprove(address, address, address, address) internal pure override returns (bool) {
        return false;
    }

    function _isERC6551() internal pure override returns (bool) {
        return false;
    }
}
