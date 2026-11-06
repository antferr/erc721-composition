// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Variant6551, VariantCustom} from "../utils/Variant.sol";
import {CompositionSpec} from "./CompositionSpec.sol";

/// @dev Groups A-C on variant 1: containers are ERC-6551 accounts.
contract SpecERC6551Test is CompositionSpec, Variant6551 {}

/// @dev Groups A-C on variant 2: containers are minimal custom contracts.
contract SpecCustomContainerTest is CompositionSpec, VariantCustom {}
