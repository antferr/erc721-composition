# ERC-721 Composition Extension: reference implementation and tests

[![CI](https://github.com/antferr/erc721-composition/actions/workflows/test.yml/badge.svg)](https://github.com/antferr/erc721-composition/actions/workflows/test.yml)

Reference implementation and tests for a proposed ERC-721 extension for tokens that hold assets in a container of their own: nothing leaves the container while the token exists, any contract can read what the token was minted with, and after the burn only the address recorded by ERC-8423 can take the assets out.

The proposal is under discussion and has no number yet. Feedback on the semantics belongs in the discussion thread:
https://ethereum-magicians.org/t/erc-721-composition-extension/30181

It builds on ERC-8423, under review as pull request https://github.com/ethereum/ERCs/pull/2032, whose reference implementation is in https://github.com/antferr/erc721-burn-record.

**This code has not been audited.** It exists to test the proposal, not to hold assets of value.

## Why

ERC-6551's Security Considerations walk through a case every buyer of a token with an account should know: Alice's token owns an account holding 10 ETH, Bob offers to buy the token, Alice empties the account and accepts the offer, and Bob receives an empty token. Among the mitigations, they suggest a list of the assets expected to stay in the account and a lock that keeps the owner from taking them out, and leave both to marketplaces and implementations.

This extension takes up those two suggestions for one kind of token. Each token declares at mint what it is made of and keeps it in a container that nobody can operate while the token exists. Without a common interface, a marketplace, an indexer or a wallet cannot tell a lower bound it can verify from a figure in the metadata, and falls back on the balance, which says what is there now, not what is bound to stay.

## Interface

```solidity
/// @dev The ERC-165 identifier for this interface is 0xd60a6c7e
interface IERC721Composition /* is IERC721, IERC721BurnRecord, IERC165 */ {
    /// @param asset  The ERC-20 contract, or 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE (ERC-7528) for the native asset
    /// @param amount The declared amount, in the asset's smallest unit, never zero
    struct Constituent {
        address asset;
        uint256 amount;
    }

    /// @notice Emitted once per token, in the transaction that mints it, batch mints included
    event CompositionDeclared(
        uint256 indexed tokenId,
        address indexed account,
        bytes4 accountType,
        bytes accountData,
        Constituent[] constituents
    );

    /// @notice The declared composition, fixed at mint, sorted by asset address
    function compositionOf(uint256 tokenId) external view returns (Constituent[] memory constituents);

    /// @notice The container that holds the constituents, its type, and the data to verify it
    function compositionAccountOf(uint256 tokenId)
        external
        view
        returns (address account, bytes4 accountType, bytes memory accountData);
}
```

`accountType` is the ERC-165 identifier of the container's interface, which the container confirms through `supportsInterface`. For an ERC-6551 account it is `0x6faff5f1`, `accountData` is `abi.encode(implementation, salt)`, and `account` is the address the canonical registry computes for this chain, this contract and this token id. Other container types define their own data.

## Rules in brief

The normative text will be the Specification of the ERC. These are the rules published in the discussion thread, numbered as there; the last three come from its third post.

1. **Locked until the burn.** While the token exists, the container does not execute, approve or validate anything that moves its assets out; after the burn, only the address returned by `burnedBy` can move them. The rule cannot be changed later, and on any other chain the container validates nothing.
2. **ERC-6551 accounts:** before the burn, `isValidSigner` and `isValidSignature` never return their magic values; after the burn, they do only for the burner.
3. **One container per token,** used by no other token.
4. **Fixed at mint.** Composition and container never change, not even after the burn.
5. **A lower bound.** When the minting transaction ends, the container holds at least each declared amount, and no declared amount exceeds what the container actually received. Anything sent later is surplus: it stays inside and leaves with the rest after the burn.
6. **One event per token,** at mint, batch mints included, with the same data the two functions return.
7. **No re-minting** of a burned id, so the recorded burner of a token never changes.
8. **No reverts.** Both functions answer for any id. An empty composition means "not declared", never "declared as zero"; after the burn they return the same values as before.
9. **Constituents** are the native asset and ERC-20 tokens, each at most once, sorted by address, with amounts above zero. Tokens whose balance can drop without a transfer by the holder should not be declared: no container can protect their lower bound.
10. **Already a contract.** When the minting transaction ends, the container is a contract, so a reader can run its checks straight away.
11. **No upgrades.** For an ERC-6551 account, the implementation in `accountData` is the code that runs behind the registry's proxy, and it is neither upgradeable nor delegating.
12. **No token of the collection goes into a container the collection has declared,** its own or another token's, live or burned, by transfer or by mint. Within the collection this rules out every ownership cycle: a token inside another token's container is always older than that token.

Where each fact is read, as published in the thread:

| Fact | Read with | Announced by | Changed by |
|---|---|---|---|
| Declared composition, the lower bound | `compositionOf` | `CompositionDeclared`, at mint | Nothing, fixed at mint |
| Container, its type and verification data | `compositionAccountOf` | `CompositionDeclared`, at mint | Nothing, fixed at mint |
| Owner when the token was burned | `burnedBy` (ERC-8423) | `Transfer` to the zero address | Only the burn, once |
| What the container holds now | The constituents: `balanceOf`, or the native balance | Nothing in this extension | Later deposits, actions by a constituent's issuer, withdrawals after the burn |

The comment on each test starts with its identifier and the rules it checks: P1 to P12 are the rules above, FT1 to FT4 the rows of this table, I1 to I4 the interface (identifier, constituent, container data, event), and BR2, BR4, BR5 and BR7 the rules with the same number in the specification of ERC-8423.

## What a reader still has to check

The two functions tell a reader which container holds the assets and which code governs it; they cannot tell whether that code really keeps the assets in. A reader recognises two pieces of code: the container's, and the token contract's, because the container opens for whoever `burnedBy` names. `src/examples/CompositionReader.sol` does this for both container types without knowing the collection, and `test/Reader.t.sol` shows it turning away an ordinary account the holder can empty, an account behind an upgradeable proxy, a token contract with a rigged `burnedBy`, a container that belongs to another token, and hostile contracts that return enormous or malformed answers.

So the declared composition is a lower bound a reader can check under these conditions, not a statement about what the token is worth. Even with both pieces of code recognised, the balance of a constituent can fall below the declared amount without any action of the container, if its issuer can rebase it down, freeze it or seize it: the reader compares the current balances with the declared amounts and says so.

## Limits shown by the tests

- A burner that has no way to call the container leaves the content locked for good (`test_IntermediaryBurner_ContentStuck`). Wallets and marketplaces should let the owner perform the burn.
- A token sent into a minimal custom container stays there: that container moves only the native asset and ERC-20 tokens. Through an ERC-6551 account, the burner can take it out after the burn.
- Cycles that pass through other accounts of the same tokens, or through another collection, are not prevented (`test/Cycles.t.sol`).
- Assets sent to the address of a container before its token is minted become surplus, locked with the rest and released to the burner (`test_PrefundedAddress_BecomesSurplus`).
- An account behind an upgradeable proxy keeps its address, its code and its declared data while becoming withdrawable: only recognising the implementation itself rules it out (`test_Reader_RejectsUpgradeableProxyAccount`).

## Building a collection

Inherit `ERC721Composition`, call `_declareComposition` for every token in the transaction that mints it, before any untrusted external call, and implement `_accountTypeAndData`. `ERC721CompositionMint` is an example minting flow in which whoever mints supplies the constituents. `CompositionToken` and `CustomContainerCompositionToken` are complete collections for the two container types, and `ConsecutiveCompositionToken` mints in batch during construction.

## Layout

| Path | Content |
|---|---|
| `src/IERC721Composition.sol` | The interface, as published in the discussion thread |
| `src/ERC721Composition.sol` | The extension: declarations, the two functions, the event, the checks on transfers and mints |
| `src/ERC721CompositionMint.sol` | An example minting flow; minting is outside the interface |
| `src/CompositionToken.sol` | Collection whose containers are ERC-6551 accounts from the canonical registry |
| `src/CustomContainerCompositionToken.sol` | Collection whose containers are minimal contracts of its own |
| `src/ConsecutiveCompositionToken.sol` | Batch mint during construction, with one event per token |
| `src/LockedERC6551Account.sol` | ERC-6551 account locked until the burn, adapted from the example account in the ERC-6551 text |
| `src/LockedContainer.sol` | Minimal custom container |
| `src/interfaces/IERC6551.sol` | ERC-6551 interfaces |
| `src/examples/CompositionReader.sol` | Example reader for collections it does not know |
| `test/spec/` | Specification tests, written once and run on both container types |
| `test/Lock6551.t.sol` | The two calls ERC-6551 accounts must spell out, and a token that accepts ERC-1271 authorizations |
| `test/Cycles.t.sol` | Ownership cycles the extension does not prevent |
| `test/Constituents.t.sol` | Fee-on-transfer, rebasing, freezable and hostile tokens; accounts and assets that exist before the mint |
| `test/Reader.t.sol` | The example reader against correct and defective collections |
| `test/Gas.t.sol` | Cost |
| `test/invariant/` | Random sequences, checked after every step against a model built from the operations |
| `test/Defects.t.sol` | Thirteen defects introduced on purpose, each caught by the checks of the specification tests |
| `test/mocks/` | Test tokens and accounts, and the defective contracts |
| `test/data/` | Deployment data of the ERC-6551 registry, copied from the ERC text: the tests run against the real registry code at its canonical address |
| `.github/workflows/test.yml` | Continuous integration: format check, build and tests |

## Build and test

Requires [Foundry](https://getfoundry.sh). The dependencies are not vendored: install them at the pinned versions after cloning.

```sh
git clone https://github.com/antferr/erc721-composition
cd erc721-composition
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0 antferr/erc721-burn-record@465f74f966bb56b6812e97f9c8356fba0e63f2d9
forge test
```

The same steps run on GitHub Actions at every push, with Foundry v1.8.3. Each fuzz test runs 1,000 times, and the invariants 256 sequences of 100 calls for each container type. A longer campaign, run once before each report:

```sh
FOUNDRY_FUZZ_RUNS=10000 forge test --match-test testFuzz
FOUNDRY_INVARIANT_RUNS=1000 forge test --match-test invariant
```

## Measured cost

Whole transactions, including the base cost of 21,000 gas; reads as paid by another contract that calls them. solc 0.8.37, EVM version osaka, optimizer at 200 runs. Run `forge test --match-test test_Gas -vv` to repeat them.

| Operation | ERC-6551 account | Custom container |
|---|---|---|
| Mint, plain ERC-721 for comparison | 68,759 | 68,759 |
| Mint, 1 constituent (native asset) | 261,266 | 485,611 |
| Mint, 3 constituents | 412,015 | 636,365 |
| Mint, 8 constituents | 831,609 | 1,056,002 |
| Transfer (plain ERC-721: 59,866) | 62,585 | 62,508 |
| Burn | 59,206 | 59,184 |
| Withdrawal after the burn: native asset, then an ERC-20 | 63,470 and 55,846 | 43,493 and 52,283 |
| `compositionOf`, read, with 1, 3 and 8 constituents | 7,632, 17,047 and 40,588 | Same |
| `compositionAccountOf`, read | 3,039 | 2,935 |
| Extra cost per token, batch mint during construction | 174,239 | |
| `CompositionDeclared` alone, per token, with 1 and 3 constituents | 4,690 and 5,758 | |

A custom container costs a contract creation per token. The check on transfers adds about 2,700 gas over a plain ERC-721 transfer.

## Status

Proposal under discussion, without a number. The interface is the one published in the discussion thread; it may still change while the proposal is a draft, and this repository will follow it.

## License

[CC0-1.0](LICENSE). Author: Antonio Ferraioli.
