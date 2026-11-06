// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Composition} from "../../src/IERC721Composition.sol";
import {ERC721Composition} from "../../src/ERC721Composition.sol";
import {LockedContainer, ILockedContainer} from "../../src/LockedContainer.sol";
import {IERC6551Executable, IERC6551Registry} from "../../src/interfaces/IERC6551.sol";
import {Holder} from "../mocks/Holders.sol";
import {ICompositionToken, IForceMint} from "../utils/Variant.sol";

/// @dev Drives random sequences against a composition token and keeps an independent model,
///      built from the operations the handler performs and never from what the contract
///      answers. Actions that must fail are attempted, and must fail with the expected error;
///      their logs are discarded, as a chain discards the logs of a failed call. Actions that
///      must succeed revert the handler if they fail, which `fail_on_revert` turns into a
///      failed run.
abstract contract CompositionHandler is Test {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MAX_PIECES = 12;

    ICompositionToken public immutable token;
    Holder public immutable holder;
    address internal immutable stranger;
    /// @dev Alice, Bob, Carol, then the holder contract `H`. Only the first three fund mints.
    address[4] internal actors;
    /// @dev The ordinary constituents, sorted by address.
    address[3] public assets;

    enum Kind {
        Actor,
        DeclaredContainer,
        FutureContainer
    }

    // ------------------------------------------------------------ the model

    uint256 public minted;
    /// @dev Expected container of every id up to MAX_PIECES, computed once, before any mint.
    mapping(uint256 tokenId => address) public containerOf;
    mapping(address container => uint256 tokenId) public pieceOfContainer;
    mapping(uint256 tokenId => address) public modelOwner;
    mapping(uint256 tokenId => bool) public burned;
    mapping(uint256 tokenId => address) public burnerOf;
    mapping(uint256 tokenId => bytes32) public declarationHash;
    mapping(uint256 tokenId => mapping(address asset => uint256)) public declared;
    mapping(address container => mapping(address asset => uint256)) public expectedBalance;
    mapping(uint256 tokenId => address) internal approvedFor;
    mapping(address owner => mapping(address operator => bool)) internal approvedForAll;

    // ------------------------------------------------------------ the index, from logs only

    mapping(uint256 tokenId => bytes32) public indexHash;
    mapping(uint256 tokenId => uint256) public eventCount;
    uint256 public eventsOutsideMint;

    // ------------------------------------------------------------ outcomes

    /// @dev Assets or pieces that left a container without the burner asking.
    uint256 public unexpectedExits;
    mapping(bytes32 category => uint256) public acceptedButShouldFail;
    mapping(bytes32 category => uint256) public failedWithWrongError;
    /// @dev How often each interesting case was reached, to show the sequences get there.
    mapping(bytes32 what => uint256) public reached;

    constructor(address token_, address alice, address bob, address carol, address stranger_, address x, address y) {
        token = ICompositionToken(token_);
        holder = new Holder();
        stranger = stranger_;
        actors = [alice, bob, carol, address(holder)];
        address[3] memory sorted = [NATIVE, x, y];
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && sorted[j - 1] > sorted[j]; --j) {
                (sorted[j - 1], sorted[j]) = (sorted[j], sorted[j - 1]);
            }
        }
        assets = sorted;
    }

    /// @dev Called by the concrete handler once its own parameters are set.
    function _precomputeContainers() internal {
        for (uint256 id = 1; id <= MAX_PIECES; ++id) {
            address c = _predictContainer(id);
            containerOf[id] = c;
            pieceOfContainer[c] = id;
        }
    }

    // ------------------------------------------------------------ variant hooks

    function _predictContainer(uint256 tokenId) internal view virtual returns (address);

    function _expectedType() internal view virtual returns (bytes4);

    function _expectedData() internal view virtual returns (bytes memory);

    /// @dev Calldata that asks `container` to send `amount` of `asset` to `to`.
    function _exitCalldata(address asset, address to, uint256 amount) internal view virtual returns (bytes memory);

    /// @dev Calldata that asks `container` to send the piece `tokenId` it holds to `to`.
    function _pieceExitCalldata(address container, uint256 tokenId, address to)
        internal
        view
        virtual
        returns (bytes memory);

    /// @dev Whether the burner can take back a piece held by the container.
    function _burnerCanMovePieces() internal pure virtual returns (bool);

    /// @dev The selectors the fuzzer may call.
    function actions() external view virtual returns (bytes4[] memory list) {
        list = new bytes4[](8);
        list[0] = this.mint.selector;
        list[1] = this.transfer.selector;
        list[2] = this.approve.selector;
        list[3] = this.burn.selector;
        list[4] = this.deposit.selector;
        list[5] = this.tryWithdraw.selector;
        list[6] = this.withdrawAsBurner.selector;
        list[7] = this.tryRemint.selector;
    }

    // ------------------------------------------------------------ actions

    /// @notice An actor mints with random amounts. The receiver is an actor, a declared
    ///         container (own or another piece's, live or burned) or the address of a future
    ///         piece's container.
    function mint(uint256 minterSeed, uint256 receiverSeed, uint256 nativeAmount, uint256 xAmount, uint256 yAmount)
        external
    {
        if (minted >= MAX_PIECES) return;
        uint256 id = minted + 1;
        address minter = actors[minterSeed % 3];
        IERC721Composition.Constituent[] memory c = _composition(nativeAmount, xAmount, yAmount);

        (address to, Kind kind) = _receiver(receiverSeed, id, true);
        bytes memory expectedError;
        if (kind == Kind.DeclaredContainer) {
            expectedError = abi.encodeWithSelector(
                ERC721Composition.TransferToDeclaredContainer.selector, id, pieceOfContainer[to]
            );
        } else if (kind == Kind.FutureContainer && to.code.length != 0) {
            // an account created in advance has code and no onERC721Received: ERC-721's own rule
            expectedError = abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, to);
        }

        vm.recordLogs();
        (bool ok, bytes memory ret) =
            _act(minter, address(token), _nativeOf(c), abi.encodeCall(ICompositionToken.mint, (to, c)));
        if (expectedError.length != 0) {
            _finish(false, 0);
            _expectFailure("container", ok, ret, expectedError);
            ++reached[
                kind == Kind.DeclaredContainer
                    ? bytes32("mint into declared container")
                    : bytes32("mint into created account")
            ];
            return;
        }
        require(ok, "a mint that had to succeed failed");
        require(abi.decode(ret, (uint256)) == id, "unexpected token id");

        minted = id;
        modelOwner[id] = to;
        address container = containerOf[id];
        for (uint256 i; i < c.length; ++i) {
            declared[id][c[i].asset] = c[i].amount;
            expectedBalance[container][c[i].asset] += c[i].amount;
        }
        declarationHash[id] = keccak256(abi.encode(c, container, _expectedType(), _expectedData()));
        _finish(true, id);
        ++reached[kind == Kind.FutureContainer ? bytes32("mint into future container") : bytes32("mint")];
    }

    /// @notice The owner of a piece transfers it, to the same kinds of receiver as `mint`.
    function transfer(uint256 pieceSeed, uint256 receiverSeed) external {
        (bool found, uint256 id) = _freePiece(pieceSeed);
        if (!found) return;
        address from = modelOwner[id];
        (address to, Kind kind) = _receiver(receiverSeed, id, false);
        if (to == from) return;

        vm.recordLogs();
        (bool ok, bytes memory ret) =
            _act(from, address(token), 0, abi.encodeCall(IERC721.transferFrom, (from, to, id)));
        if (kind == Kind.DeclaredContainer) {
            _finish(false, 0);
            _expectFailure(
                "container",
                ok,
                ret,
                abi.encodeWithSelector(ERC721Composition.TransferToDeclaredContainer.selector, id, pieceOfContainer[to])
            );
            ++reached[
                pieceOfContainer[to] == id
                    ? bytes32("transfer into own container")
                    : bytes32("transfer into declared container")
            ];
            return;
        }
        require(ok, "a transfer that had to succeed failed");
        modelOwner[id] = to;
        delete approvedFor[id];
        _finish(true, 0);
        ++reached[kind == Kind.FutureContainer ? bytes32("transfer into future container") : bytes32("transfer")];
    }

    /// @notice The owner approves another actor, for one piece or for all its pieces.
    function approve(uint256 pieceSeed, uint256 operatorSeed, bool forAll) external {
        (bool found, uint256 id) = _freePiece(pieceSeed);
        if (!found) return;
        address owner = modelOwner[id];
        address operator = actors[operatorSeed % 4];
        if (operator == owner) return;
        bytes memory data = forAll
            ? abi.encodeCall(IERC721.setApprovalForAll, (operator, true))
            : abi.encodeCall(IERC721.approve, (operator, id));
        vm.recordLogs();
        (bool ok,) = _act(owner, address(token), 0, data);
        require(ok, "an approval failed");
        _finish(true, 0);
        if (forAll) approvedForAll[owner][operator] = true;
        else approvedFor[id] = operator;
        ++reached["approval"];
    }

    /// @notice The owner, or another actor, burns a piece. The burner is always the owner.
    function burn(uint256 pieceSeed, uint256 callerSeed) external {
        (bool found, uint256 id) = _freePiece(pieceSeed);
        if (!found) return;
        address owner = modelOwner[id];
        // the owner, an operator it approved if there is one, or any actor
        uint256 mode = callerSeed % 3;
        address caller = mode == 2 ? actors[(callerSeed / 3) % 4] : owner;
        if (mode == 1) {
            if (approvedFor[id] != address(0)) caller = approvedFor[id];
            for (uint256 i; i < 4; ++i) {
                if (approvedForAll[owner][actors[i]]) caller = actors[i];
            }
        }
        bool authorized = caller == owner || approvedFor[id] == caller || approvedForAll[owner][caller];

        vm.recordLogs();
        (bool ok, bytes memory ret) = _act(caller, address(token), 0, abi.encodeWithSignature("burn(uint256)", id));
        if (!authorized) {
            _finish(false, 0);
            _expectFailure(
                "burn", ok, ret, abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, caller, id)
            );
            ++reached["burn refused"];
            return;
        }
        require(ok, "an authorized burn failed");
        burned[id] = true;
        burnerOf[id] = owner;
        delete modelOwner[id];
        delete approvedFor[id];
        _finish(true, 0);
        ++reached[caller == owner ? bytes32("burn by owner") : bytes32("burn by operator")];
    }

    /// @notice An actor sends an ordinary asset to the container of any piece, minted or not.
    function deposit(uint256 depositorSeed, uint256 pieceSeed, uint256 assetSeed, uint256 amount) external {
        address depositor = actors[depositorSeed % 3];
        uint256 k = 1 + pieceSeed % MAX_PIECES;
        address container = containerOf[k];
        address asset = assets[assetSeed % 3];
        amount = _bound(amount, 1, asset == NATIVE ? 1 ether : 100e18);
        bytes memory data = asset == NATIVE ? bytes("") : abi.encodeCall(IERC20.transfer, (container, amount));
        vm.recordLogs();
        (bool ok,) = _act(depositor, asset == NATIVE ? container : asset, asset == NATIVE ? amount : 0, data);
        require(ok, "a deposit failed");
        _finish(true, 0);
        expectedBalance[container][asset] += amount;
        ++reached[k > minted ? bytes32("deposit before mint") : bytes32("deposit")];
    }

    /// @notice Anyone tries to take something out of a container. It must fail, unless the
    ///         piece is burned and the caller is its burner.
    function tryWithdraw(uint256 callerSeed, uint256 pieceSeed, uint256 contentSeed, uint256 amount) external {
        uint256 k = 1 + pieceSeed % MAX_PIECES;
        address container = containerOf[k];
        address caller = _anyCaller(callerSeed);
        if (burned[k] && caller == burnerOf[k]) {
            _withdrawAsBurner(k, contentSeed, amount);
            return;
        }
        (bool isPiece, address asset, uint256 nestedId) = _pickContent(container, contentSeed);
        if (isPiece) {
            vm.recordLogs();
            _act(caller, container, 0, _pieceExitCalldata(container, nestedId, caller));
            _finish(false, 0);
            if (token.ownerOf(nestedId) != container) ++unexpectedExits;
            ++reached["piece exit refused"];
            return;
        }
        uint256 before = _balance(asset, container);
        amount = _bound(amount, 1, before == 0 ? 1 : before);
        vm.recordLogs();
        _act(caller, container, 0, _exitCalldata(asset, caller, amount));
        _finish(false, 0);
        if (_balance(asset, container) < before) ++unexpectedExits;
        ++reached[burned[k] ? bytes32("exit refused after burn") : bytes32("exit refused before burn")];
    }

    /// @notice The burner of a burned piece takes out part of the content.
    function withdrawAsBurner(uint256 pieceSeed, uint256 contentSeed, uint256 amount) external {
        if (minted == 0) return;
        for (uint256 i; i < minted; ++i) {
            uint256 k = 1 + (pieceSeed % minted + i) % minted;
            if (burned[k]) {
                _withdrawAsBurner(k, contentSeed, amount);
                return;
            }
        }
    }

    /// @notice Tries to mint again, through the internal path, an id in any state.
    function tryRemint(uint256 idSeed, uint256 receiverSeed) external {
        uint256 id = idSeed % (MAX_PIECES + 2);
        address to = actors[receiverSeed % 4];
        bytes memory expectedError;
        if (id != 0 && id <= minted) {
            expectedError = burned[id]
                ? abi.encodeWithSelector(ERC721Composition.BurnedTokenRemint.selector, id)
                : abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0));
        } else {
            expectedError = abi.encodeWithSelector(ERC721Composition.CompositionNotDeclared.selector, id);
        }
        vm.recordLogs();
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IForceMint.forceMint, (to, id)));
        _finish(false, 0);
        _expectFailure("remint", ok, ret, expectedError);
        ++reached[id != 0 && id <= minted && burned[id] ? bytes32("remint of burned id") : bytes32("remint other")];
    }

    // ------------------------------------------------------------ helpers

    function _withdrawAsBurner(uint256 k, uint256 contentSeed, uint256 amount) internal {
        address container = containerOf[k];
        address burner = burnerOf[k];
        (bool isPiece, address asset, uint256 nestedId) = _pickContent(container, contentSeed);
        if (isPiece) {
            if (!_burnerCanMovePieces()) return;
            vm.recordLogs();
            (bool moved,) = _act(burner, container, 0, _pieceExitCalldata(container, nestedId, burner));
            require(moved, "the burner could not take a piece back");
            _finish(true, 0);
            modelOwner[nestedId] = burner;
            delete approvedFor[nestedId];
            ++reached["burner takes a piece back"];
            return;
        }
        uint256 available = expectedBalance[container][asset];
        if (available == 0) return;
        amount = _bound(amount, 1, available);
        vm.recordLogs();
        (bool ok,) = _act(burner, container, 0, _exitCalldata(asset, burner, amount));
        require(ok, "the burner could not withdraw");
        _finish(true, 0);
        expectedBalance[container][asset] -= amount;
        ++reached[
            burner == address(holder) ? bytes32("withdrawal by contract burner") : bytes32("withdrawal by burner")
        ];
    }

    /// @dev Calls `target` as `actor`: a prank for people, a forwarded call for the holder
    ///      contract. Never reverts: the outcome is returned.
    function _act(address actor, address target, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (actor == address(holder)) {
            try holder.call(target, value, data) returns (bytes memory result) {
                return (true, result);
            } catch (bytes memory reason) {
                return (false, reason);
            }
        }
        vm.prank(actor);
        (ok, ret) = target.call{value: value}(data);
    }

    /// @dev Ingests the logs of the step into the index if the step succeeded. A declaration
    ///      event is expected only for `mintedId`, in the step that mints it.
    function _finish(bool succeeded, uint256 mintedId) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!succeeded) return;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(token) || logs[i].topics.length == 0
                    || logs[i].topics[0] != IERC721Composition.CompositionDeclared.selector
            ) continue;
            uint256 id = uint256(logs[i].topics[1]);
            if (id != mintedId || mintedId == 0) {
                ++eventsOutsideMint;
                continue;
            }
            ++eventCount[id];
            address account = address(uint160(uint256(logs[i].topics[2])));
            (bytes4 accountType, bytes memory accountData, IERC721Composition.Constituent[] memory c) =
                abi.decode(logs[i].data, (bytes4, bytes, IERC721Composition.Constituent[]));
            indexHash[id] = keccak256(abi.encode(c, account, accountType, accountData));
        }
    }

    function _expectFailure(bytes32 category, bool ok, bytes memory ret, bytes memory expectedError) internal {
        if (ok) ++acceptedButShouldFail[category];
        else if (keccak256(ret) != keccak256(expectedError)) ++failedWithWrongError[category];
    }

    function _composition(uint256 nativeAmount, uint256 xAmount, uint256 yAmount)
        internal
        view
        returns (IERC721Composition.Constituent[] memory c)
    {
        uint256[3] memory amounts;
        for (uint256 i; i < 3; ++i) {
            if (assets[i] == NATIVE) amounts[i] = _bound(nativeAmount, 0, 2 ether);
            else if (i == _indexOfX()) amounts[i] = _bound(xAmount, 0, 1_000e18);
            else amounts[i] = _bound(yAmount, 0, 1_000e18);
        }
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] != 0) ++n;
        }
        if (n == 0) {
            for (uint256 i; i < 3; ++i) {
                if (assets[i] == NATIVE) amounts[i] = 1;
            }
            n = 1;
        }
        c = new IERC721Composition.Constituent[](n);
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] != 0) c[k++] = IERC721Composition.Constituent(assets[i], amounts[i]);
        }
    }

    /// @dev Position of the first ERC-20 in `assets`, so that each seed keeps its asset.
    function _indexOfX() internal view returns (uint256 i) {
        while (assets[i] == NATIVE) ++i;
    }

    /// @dev Half of the time an actor, so that free pieces keep circulating; otherwise a
    ///      declared container (own, or any minted piece's, live or burned) or the address of a
    ///      future piece's container. For a mint, the piece being minted is not future: its
    ///      container is declared before the token is created.
    function _receiver(uint256 seed, uint256 id, bool minting) internal view returns (address to, Kind kind) {
        uint256 choice = seed % 8;
        uint256 r = seed / 8;
        if (choice == 4) return (containerOf[id], Kind.DeclaredContainer);
        if (choice == 5 && minted != 0) return (containerOf[1 + r % minted], Kind.DeclaredContainer);
        if (choice >= 6) {
            uint256 first = (minting ? id : minted) + 1;
            if (first <= MAX_PIECES) return (containerOf[first + r % (MAX_PIECES - first + 1)], Kind.FutureContainer);
        }
        return (actors[r % 4], Kind.Actor);
    }

    /// @dev A live piece owned by an actor, starting the search from the seed.
    function _freePiece(uint256 seed) internal view returns (bool, uint256) {
        for (uint256 i; i < minted; ++i) {
            uint256 id = 1 + (seed % minted + i) % minted;
            if (!burned[id] && _isActor(modelOwner[id])) return (true, id);
        }
        return (false, 0);
    }

    function _isActor(address a) internal view returns (bool) {
        return a == actors[0] || a == actors[1] || a == actors[2] || a == actors[3];
    }

    /// @dev The actors, a stranger, or the token contract itself.
    function _anyCaller(uint256 seed) internal view returns (address) {
        uint256 choice = seed % 6;
        if (choice < 4) return actors[choice];
        return choice == 4 ? stranger : address(token);
    }

    /// @dev One of the ordinary assets, or a piece that the container holds.
    function _pickContent(address container, uint256 seed)
        internal
        view
        returns (bool isPiece, address asset, uint256 nestedId)
    {
        uint256 nested;
        for (uint256 id = 1; id <= minted; ++id) {
            if (!burned[id] && modelOwner[id] == container) ++nested;
        }
        uint256 choice = seed % (3 + nested);
        if (choice < 3) return (false, assets[choice], 0);
        uint256 skip = choice - 3;
        for (uint256 id = 1; id <= minted; ++id) {
            if (!burned[id] && modelOwner[id] == container) {
                if (skip == 0) return (true, address(0), id);
                --skip;
            }
        }
    }

    function _nativeOf(IERC721Composition.Constituent[] memory c) internal pure returns (uint256 amount) {
        for (uint256 i; i < c.length; ++i) {
            if (c[i].asset == NATIVE) amount = c[i].amount;
        }
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == NATIVE ? account.balance : IERC20(asset).balanceOf(account);
    }

    function actorList() external view returns (address[4] memory) {
        return actors;
    }
}

/// @dev Variant 1: ERC-6551 accounts from the canonical registry. Anyone may create an account
///      in advance through the registry (P10), which the sequences also do.
contract Handler6551 is CompositionHandler {
    IERC6551Registry internal constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    address public immutable implementation;

    constructor(
        address token_,
        address implementation_,
        address alice,
        address bob,
        address carol,
        address stranger_,
        address x,
        address y
    ) CompositionHandler(token_, alice, bob, carol, stranger_, x, y) {
        implementation = implementation_;
        _precomputeContainers();
    }

    function actions() external view override returns (bytes4[] memory list) {
        list = new bytes4[](9);
        list[0] = this.mint.selector;
        list[1] = this.transfer.selector;
        list[2] = this.approve.selector;
        list[3] = this.burn.selector;
        list[4] = this.deposit.selector;
        list[5] = this.tryWithdraw.selector;
        list[6] = this.withdrawAsBurner.selector;
        list[7] = this.tryRemint.selector;
        list[8] = this.createAccountInAdvance.selector;
    }

    /// @notice A stranger creates through the registry the account of a piece not yet minted.
    function createAccountInAdvance(uint256 pieceSeed) external {
        if (minted >= MAX_PIECES) return;
        uint256 k = minted + 1 + pieceSeed % (MAX_PIECES - minted);
        vm.recordLogs();
        vm.prank(stranger);
        address created = REGISTRY.createAccount(implementation, bytes32(0), block.chainid, address(token), k);
        _finish(true, 0);
        require(created == containerOf[k], "registry address differs from the model");
        ++reached["account created in advance"];
    }

    function _predictContainer(uint256 tokenId) internal view override returns (address) {
        return REGISTRY.account(implementation, bytes32(0), block.chainid, address(token), tokenId);
    }

    function _expectedType() internal pure override returns (bytes4) {
        return 0x6faff5f1;
    }

    function _expectedData() internal view override returns (bytes memory) {
        return abi.encode(implementation, bytes32(0));
    }

    function _exitCalldata(address asset, address to, uint256 amount) internal pure override returns (bytes memory) {
        if (asset == NATIVE) return abi.encodeCall(IERC6551Executable.execute, (to, amount, "", 0));
        return abi.encodeCall(IERC6551Executable.execute, (asset, 0, abi.encodeCall(IERC20.transfer, (to, amount)), 0));
    }

    function _pieceExitCalldata(address container, uint256 tokenId, address to)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeCall(
            IERC6551Executable.execute,
            (address(token), 0, abi.encodeCall(IERC721.transferFrom, (container, to, tokenId)), 0)
        );
    }

    function _burnerCanMovePieces() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Variant 2: one minimal container per token, created by the token contract. A piece
///      held by such a container stays there for good: the container moves only the native
///      asset and ERC-20 tokens.
contract HandlerCustom is CompositionHandler {
    constructor(address token_, address alice, address bob, address carol, address stranger_, address x, address y)
        CompositionHandler(token_, alice, bob, carol, stranger_, x, y)
    {
        _precomputeContainers();
    }

    function _predictContainer(uint256 tokenId) internal view override returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(LockedContainer).creationCode, abi.encode(address(token), tokenId)));
        return vm.computeCreate2Address(bytes32(tokenId), initCodeHash, address(token));
    }

    function _expectedType() internal pure override returns (bytes4) {
        return type(ILockedContainer).interfaceId;
    }

    function _expectedData() internal pure override returns (bytes memory) {
        return "";
    }

    function _exitCalldata(address asset, address to, uint256 amount) internal pure override returns (bytes memory) {
        return abi.encodeCall(ILockedContainer.withdraw, (asset, to, amount));
    }

    function _pieceExitCalldata(address, uint256 tokenId, address to) internal view override returns (bytes memory) {
        // the only exit there is: it treats the piece as an ERC-20 amount and fails
        return abi.encodeCall(ILockedContainer.withdraw, (address(token), to, tokenId));
    }

    function _burnerCanMovePieces() internal pure override returns (bool) {
        return false;
    }
}
