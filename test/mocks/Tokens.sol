// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @dev Ordinary ERC-20 with open minting.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 that keeps 1% of every transfer: the recipient receives less than the amount.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("FeeOnTransfer", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @dev ERC-20 whose balances are shares times an index that the issuer can lower: every
///      balance drops at once, without any transfer by the holder.
contract RebasingDownERC20 {
    uint256 internal constant ONE = 1e18;

    string public constant name = "RebasingDown";
    string public constant symbol = "RBD";
    uint8 public constant decimals = 18;
    address public immutable issuer;
    uint256 public index = ONE;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        issuer = msg.sender;
    }

    function balanceOf(address account) public view returns (uint256) {
        return sharesOf[account] * index / ONE;
    }

    function mint(address to, uint256 amount) external {
        sharesOf[to] += amount * ONE / index;
        emit Transfer(address(0), to, amount);
    }

    /// @dev The issuer lowers every balance, for example to 70% with 0.7e18.
    function rebaseDown(uint256 newIndex) external {
        require(msg.sender == issuer && newIndex < index, "not allowed");
        index = newIndex;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 shares = amount * ONE / index;
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}

/// @dev ERC-20 whose issuer can freeze an address, so that it can neither send nor receive,
///      and seize its balance.
contract IssuerControlledERC20 is ERC20 {
    address public immutable issuer;
    mapping(address => bool) public frozen;

    constructor() ERC20("IssuerControlled", "ISC") {
        issuer = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address account, bool value) external {
        require(msg.sender == issuer, "not issuer");
        frozen[account] = value;
    }

    function seize(address account, uint256 amount) external {
        require(msg.sender == issuer, "not issuer");
        _transfer(account, issuer, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (msg.sender != issuer) {
            require(!frozen[from] && !frozen[to], "frozen");
        }
        super._update(from, to, value);
    }
}

/// @dev ERC-20 that also moves tokens on a signed authorization, accepting signatures from
///      contracts through ERC-1271, on the model of the transfer authorizations of widely used
///      tokens (checked on their sources on 28/09/2026). Written from scratch for the tests.
contract SignatureTransferERC20 is ERC20 {
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    error InvalidAuthorization();

    constructor() ERC20("SignatureTransfer", "SIG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function authorizationDigest(address from, address to, uint256 amount, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, from, to, amount, nonce));
    }

    /// @dev Anyone can submit the authorization; `from` must have signed it, through ERC-1271
    ///      when `from` is a contract.
    function transferWithSignature(address from, address to, uint256 amount, uint256 nonce, bytes calldata signature)
        external
    {
        if (usedNonces[from][nonce]) revert InvalidAuthorization();
        bytes32 digest = authorizationDigest(from, to, amount, nonce);
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidAuthorization();
        usedNonces[from][nonce] = true;
        _transfer(from, to, amount);
    }
}

/// @dev A token sent as surplus whose transfers always fail.
contract HostileERC20 is ERC20 {
    constructor() ERC20("Hostile", "HST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) revert("hostile");
        super._update(from, to, value);
    }
}
