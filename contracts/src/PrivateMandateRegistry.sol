// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifier} from "./HonkVerifier.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title  PrivateMandateRegistry
/// @notice Escrowed spend authority for AI agents where the mandate itself is
///         private. The chain stores only a Poseidon2 commitment to the terms
///         (per-tx cap, total cap, expiry, payee allowlist root, salt) and a
///         commitment to the running spend. Every payment carries an UltraHonk
///         proof that it fits the hidden terms and advances the state chain.
///
///         What an observer sees: who the principal and agent are, each payment
///         (payee + amount, because the token transfer is public anyway), and
///         an opaque commitment chain. What they do not see: the caps, the
///         expiry, the allowlist (its members or its size).
///
///         Mandates are keyed by (principal, commitment), not by the commitment
///         alone. Otherwise anyone watching the mempool could copy a principal's
///         commitment into their own `createMandate` call first and block it
///         forever (MandateExists), at the cost of one transaction per victim.
contract PrivateMandateRegistry {
    /// @dev BN254 scalar field modulus. The verifier reduces public inputs mod P,
    ///      so a non-canonical value would alias a canonical one: reject them.
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct Mandate {
        address agent; // the only address allowed to submit payments; zero means "no mandate"
        bool revoked;
        bytes32 head; // current state commitment H(TAG_STATE, commitment, spent, stateSalt)
    }

    IVerifier public immutable verifier;
    IERC20Min public immutable token;

    /// @notice Pooled escrow per principal. Pooling (rather than one escrow per
    ///         mandate) avoids leaking an upper bound on any single mandate's cap.
    mapping(address => uint256) public escrowOf;
    /// @notice mandateId(principal, commitment) => mandate
    mapping(bytes32 => Mandate) public mandates;

    uint256 private locked = 1;

    event Deposited(address indexed principal, uint256 amount);
    event Withdrawn(address indexed principal, uint256 amount);
    event MandateCreated(
        bytes32 indexed id, bytes32 indexed commitment, address indexed principal, address agent, bytes32 head
    );
    event MandateRevoked(bytes32 indexed id);
    event Paid(bytes32 indexed id, address indexed payee, uint256 amount, bytes32 newHead);

    error MandateExists();
    error MandateMissing();
    error NotAgent();
    error Revoked();
    error Expired();
    error InvalidProof();
    error InsufficientEscrow();
    error NonCanonical();
    error TransferFailed();
    error ZeroAgent();
    error NotAContract();
    error Reentrancy();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(IVerifier _verifier, IERC20Min _token) {
        // A call to an address without code "succeeds" with empty return data,
        // which the no-return-value token handling below would read as success.
        if (address(_verifier).code.length == 0 || address(_token).code.length == 0) revert NotAContract();
        verifier = _verifier;
        token = _token;
    }

    // ------------------------------------------------------------- escrow --

    /// @notice Credits the amount actually received, so a fee-on-transfer token
    ///         cannot make the pooled escrow insolvent.
    function deposit(uint256 amount) external nonReentrant {
        uint256 before = token.balanceOf(address(this));
        _call(abi.encodeCall(IERC20Min.transferFrom, (msg.sender, address(this), amount)));
        uint256 received = token.balanceOf(address(this)) - before;
        escrowOf[msg.sender] += received;
        emit Deposited(msg.sender, received);
    }

    /// @notice Withdraw unspent escrow. Not time-locked: a principal can always
    ///         pull funds out from under its own mandates (see SECURITY.md).
    function withdraw(uint256 amount) external nonReentrant {
        if (escrowOf[msg.sender] < amount) revert InsufficientEscrow();
        escrowOf[msg.sender] -= amount;
        _call(abi.encodeCall(IERC20Min.transfer, (msg.sender, amount)));
        emit Withdrawn(msg.sender, amount);
    }

    // ----------------------------------------------------------- mandates --

    /// @notice Storage key of a mandate. Two principals can never collide.
    function mandateId(address principal, bytes32 commitment) public pure returns (bytes32) {
        return keccak256(abi.encode(principal, commitment));
    }

    /// @param commitment  H(TAG_MANDATE, maxPerTx, totalCap, notAfter, allowlistRoot, salt)
    /// @param initialHead H(TAG_STATE, commitment, 0, H(TAG_SALT0, salt)), computed off-chain.
    ///                    A principal that commits a wrong head only bricks its own mandate.
    function createMandate(bytes32 commitment, bytes32 initialHead, address agent) external {
        if (agent == address(0)) revert ZeroAgent();
        if (uint256(commitment) >= P || uint256(initialHead) >= P) revert NonCanonical();
        bytes32 id = mandateId(msg.sender, commitment);
        // A revoked mandate keeps its slot, so a commitment can never be
        // re-registered with a fresh (spent = 0) head by the same principal.
        if (mandates[id].agent != address(0)) revert MandateExists();
        mandates[id] = Mandate({agent: agent, revoked: false, head: initialHead});
        emit MandateCreated(id, commitment, msg.sender, agent, initialHead);
    }

    /// @notice Permanently disables a mandate. Only its principal can reach it,
    ///         because the id is derived from msg.sender.
    function revoke(bytes32 commitment) external {
        bytes32 id = mandateId(msg.sender, commitment);
        Mandate storage m = mandates[id];
        if (m.agent == address(0)) revert MandateMissing();
        m.revoked = true;
        emit MandateRevoked(id);
    }

    /// @notice Domain binding baked into every proof: a proof generated for this
    ///         registry, on this chain, for this principal's mandate is useless
    ///         anywhere else. Shifted right 8 bits so it is always < P.
    function contextOf(address principal, bytes32 commitment) public view returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(block.chainid, address(this), principal, commitment))) >> 8);
    }

    // ------------------------------------------------------------ payment --

    /// @notice Release `amount` of the principal's escrow to `payee` iff `proof`
    ///         shows the payment fits the private mandate. The proof is checked
    ///         against the stored head, so a replayed proof (stale head) can
    ///         never verify twice.
    /// @param validUntil the proof attests validUntil <= notAfter; we require
    ///        block.timestamp <= validUntil, so expiry is enforced exactly.
    function pay(
        address principal,
        bytes32 commitment,
        address payee,
        uint64 amount,
        uint64 validUntil,
        bytes32 newHead,
        bytes calldata proof
    ) external nonReentrant {
        bytes32 id = mandateId(principal, commitment);
        Mandate storage m = mandates[id];
        if (m.agent == address(0)) revert MandateMissing();
        if (m.revoked) revert Revoked();
        if (msg.sender != m.agent) revert NotAgent();
        if (block.timestamp > validUntil) revert Expired();
        if (uint256(newHead) >= P) revert NonCanonical();

        bytes32[] memory pub = new bytes32[](7);
        // Order must match the `pub` parameters of `main` in circuits/src/main.nr.
        pub[0] = commitment;
        pub[1] = m.head;
        pub[2] = newHead;
        pub[3] = bytes32(uint256(amount));
        pub[4] = bytes32(uint256(uint160(payee)));
        pub[5] = bytes32(uint256(validUntil));
        pub[6] = contextOf(principal, commitment);

        // The generated verifier reverts (rather than returning false) on most
        // failures; normalize everything to one error.
        bool ok;
        try verifier.verify(proof, pub) returns (bool v) {
            ok = v;
        } catch {
            ok = false;
        }
        if (!ok) revert InvalidProof();

        if (escrowOf[principal] < amount) revert InsufficientEscrow();

        // Effects before the external transfer.
        m.head = newHead;
        escrowOf[principal] -= amount;
        _call(abi.encodeCall(IERC20Min.transfer, (payee, amount)));

        emit Paid(id, payee, amount, newHead);
    }

    /// @dev Token call that accepts both standard (returns true) and legacy
    ///      (returns nothing, e.g. USDT) ERC-20s, and rejects `false`.
    function _call(bytes memory data) private {
        (bool success, bytes memory ret) = address(token).call(data);
        if (!success || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
