// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC721Composition} from "../src/IERC721Composition.sol";
import {LockedERC6551Account} from "../src/LockedERC6551Account.sol";
import {IERC6551Registry} from "../src/interfaces/IERC6551.sol";
import {MockERC20} from "./mocks/Tokens.sol";

/// @dev Shared setup. The ERC-6551 registry is deployed exactly as its ERC prescribes: through
///      Nick's factory, with the salt and creation code printed in the ERC text. Landing on the
///      canonical address proves that the tests use the real registry code.
abstract contract Base is Test {
    address internal constant NICK_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes4 internal constant ERC6551_ACCOUNT_ID = 0x6faff5f1;
    bytes4 internal constant ERC6551_SIGNER_MAGIC = 0x523e3260;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant COMPOSITION_ID = 0xd60a6c7e;
    bytes4 internal constant BURN_RECORD_ID = 0x43470a89;
    /// @dev Runtime code of Nick's factory (deterministic deployment proxy), used only if the
    ///      test environment does not already provide it.
    bytes internal constant NICK_FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    LockedERC6551Account internal implementation;
    MockERC20 internal tokenX;
    MockERC20 internal tokenY;

    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;
    address internal stranger;

    function setUp() public virtual {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
        stranger = makeAddr("stranger");
        _deployCanonicalRegistry();
        implementation = new LockedERC6551Account();
        tokenX = new MockERC20("Token X", "TKX");
        tokenY = new MockERC20("Token Y", "TKY");
        address[3] memory people = [alice, bob, carol];
        for (uint256 i; i < people.length; ++i) {
            vm.deal(people[i], 1_000 ether);
            tokenX.mint(people[i], 1_000_000e18);
            tokenY.mint(people[i], 1_000_000e18);
        }
    }

    function _deployCanonicalRegistry() internal {
        if (REGISTRY.code.length != 0) return;
        if (NICK_FACTORY.code.length == 0) vm.etch(NICK_FACTORY, NICK_FACTORY_RUNTIME);
        bytes memory data = vm.parseBytes(vm.readFile("test/data/erc6551-registry-deploy-data.txt"));
        (bool ok, bytes memory ret) = NICK_FACTORY.call(data);
        require(ok, "registry deployment failed");
        require(address(bytes20(ret)) == REGISTRY, "registry not at the canonical address");
        require(REGISTRY.code.length != 0, "registry has no code");
    }

    // ------------------------------------------------------------ compositions

    /// @dev Native amount plus two ERC-20 amounts, sorted by asset address.
    function _three(uint256 nativeAmount, uint256 xAmount, uint256 yAmount)
        internal
        view
        returns (IERC721Composition.Constituent[] memory c)
    {
        c = new IERC721Composition.Constituent[](3);
        c[0] = IERC721Composition.Constituent(address(tokenX), xAmount);
        c[1] = IERC721Composition.Constituent(address(tokenY), yAmount);
        c[2] = IERC721Composition.Constituent(NATIVE, nativeAmount);
        _sort(c);
    }

    function _one(address asset, uint256 amount) internal pure returns (IERC721Composition.Constituent[] memory c) {
        c = new IERC721Composition.Constituent[](1);
        c[0] = IERC721Composition.Constituent(asset, amount);
    }

    function _two(address assetA, uint256 amountA, address assetB, uint256 amountB)
        internal
        pure
        returns (IERC721Composition.Constituent[] memory c)
    {
        c = new IERC721Composition.Constituent[](2);
        c[0] = IERC721Composition.Constituent(assetA, amountA);
        c[1] = IERC721Composition.Constituent(assetB, amountB);
        _sort(c);
    }

    function _sort(IERC721Composition.Constituent[] memory c) internal pure {
        for (uint256 i = 1; i < c.length; ++i) {
            IERC721Composition.Constituent memory key = c[i];
            uint256 j = i;
            while (j > 0 && c[j - 1].asset > key.asset) {
                c[j] = c[j - 1];
                --j;
            }
            c[j] = key;
        }
    }

    function _nativeOf(IERC721Composition.Constituent[] memory c) internal pure returns (uint256 amount) {
        for (uint256 i; i < c.length; ++i) {
            if (c[i].asset == NATIVE) amount += c[i].amount;
        }
    }

    // ------------------------------------------------------------ misc

    function _sign(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    function _expected6551(address impl, address nft, uint256 tokenId) internal view returns (address) {
        return IERC6551Registry(REGISTRY).account(impl, bytes32(0), block.chainid, nft, tokenId);
    }

    /// @dev Decodes every CompositionDeclared log emitted by `emitter` in `logs`.
    function _declaredEvents(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (
            uint256[] memory ids,
            address[] memory accounts,
            bytes4[] memory types,
            bytes[] memory datas,
            IERC721Composition.Constituent[][] memory compositions
        )
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == IERC721Composition.CompositionDeclared.selector) {
                ++n;
            }
        }
        ids = new uint256[](n);
        accounts = new address[](n);
        types = new bytes4[](n);
        datas = new bytes[](n);
        compositions = new IERC721Composition.Constituent[][](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics[0] != IERC721Composition.CompositionDeclared.selector) {
                continue;
            }
            ids[k] = uint256(logs[i].topics[1]);
            accounts[k] = address(uint160(uint256(logs[i].topics[2])));
            (types[k], datas[k], compositions[k]) =
                abi.decode(logs[i].data, (bytes4, bytes, IERC721Composition.Constituent[]));
            ++k;
        }
    }
}
