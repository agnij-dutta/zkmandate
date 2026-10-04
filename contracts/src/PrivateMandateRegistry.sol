// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifier} from "./HonkVerifier.sol";

interface IERC20Min {
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
contract PrivateMandateRegistry {
    /// @dev BN254 scalar field modulus. Commitments must be canonical field elements.
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct Mandate {
        address principal; // funds the escrow, can revoke
        address agent;     // the only address allowed to submit payments
        bool revoked;
        bytes32 head;      // current state commitment H(TAG_STATE, mandate, spent, stateSalt)
    }

    IVerifier public immutable verifier;
    IERC20Min public immutable token;

    /// @notice Pooled escrow per principal. Pooling (rather than one escrow per
    ///         mandate) avoids leaking an upper bound on any single mandate's cap.
    mapping(address => uint256) public escrowOf;
    /// @notice mandate commitment => mandate
    mapping(bytes32 => Mandate) public mandates;

    event Deposited(address indexed principal, uint256 amount);
    event Withdrawn(address indexed principal, uint256 amount);
    event MandateCreated(bytes32 indexed mandate, address indexed principal, address indexed agent, bytes32 head);
    event MandateRevoked(bytes32 indexed mandate);
    event Paid(bytes32 indexed mandate, address indexed payee, uint256 amount, bytes32 newHead);

    error MandateExists();
    error MandateMissing();
    error NotPrincipal();
    error NotAgent();
    error Revoked();
    error Expired();
    error InvalidProof();
    error InsufficientEscrow();
    error NonCanonical();
    error TransferFailed();
    error ZeroAgent();

    constructor(IVerifier _verifier, IERC20Min _token) {
        verifier = _verifier;
        token = _token;
    }

    // ------------------------------------------------------------- escrow --

    function deposit(uint256 amount) external {
        escrowOf[msg.sender] += amount;
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (escrowOf[msg.sender] < amount) revert InsufficientEscrow();
        escrowOf[msg.sender] -= amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    // ----------------------------------------------------------- mandates --

    /// @param mandate     H(TAG_MANDATE, maxPerTx, totalCap, notAfter, allowlistRoot, salt)
    /// @param initialHead H(TAG_STATE, mandate, 0, H(TAG_SALT0, salt)), computed off-chain.
    ///                    A principal that commits a wrong head only bricks its own mandate.
    function createMandate(bytes32 mandate, bytes32 initialHead, address agent) external {
        if (agent == address(0)) revert ZeroAgent();
        if (uint256(mandate) >= P || uint256(initialHead) >= P) revert NonCanonical();
        if (mandates[mandate].principal != address(0)) revert MandateExists();
        mandates[mandate] = Mandate({principal: msg.sender, agent: agent, revoked: false, head: initialHead});
        emit MandateCreated(mandate, msg.sender, agent, initialHead);
    }

    function revoke(bytes32 mandate) external {
        Mandate storage m = mandates[mandate];
        if (m.principal == address(0)) revert MandateMissing();
        if (m.principal != msg.sender) revert NotPrincipal();
        m.revoked = true;
        emit MandateRevoked(mandate);
    }

    /// @notice Domain binding baked into every proof: a proof generated for this
    ///         registry, on this chain, for this mandate is useless anywhere else.
    function contextOf(bytes32 mandate) public view returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(block.chainid, address(this), mandate))) >> 8);
    }

    // ------------------------------------------------------------ payment --

    /// @notice Release `amount` of escrow to `payee` iff `proof` shows the payment
    ///         fits the private mandate. The proof is checked against the stored
    ///         head, so a replayed proof (stale head) can never verify twice.
    /// @param validUntil the proof attests validUntil <= notAfter; we require
    ///        block.timestamp <= validUntil, so expiry is enforced exactly.
    function pay(
        bytes32 mandate,
        address payee,
        uint64 amount,
        uint64 validUntil,
        bytes32 newHead,
        bytes calldata proof
    ) external {
        Mandate storage m = mandates[mandate];
        if (m.principal == address(0)) revert MandateMissing();
        if (m.revoked) revert Revoked();
        if (msg.sender != m.agent) revert NotAgent();
        if (block.timestamp > validUntil) revert Expired();
        if (uint256(newHead) >= P) revert NonCanonical();

        bytes32[] memory pub = new bytes32[](7);
        pub[0] = mandate;
        pub[1] = m.head;
        pub[2] = newHead;
        pub[3] = bytes32(uint256(amount));
        pub[4] = bytes32(uint256(uint160(payee)));
        pub[5] = bytes32(uint256(validUntil));
        pub[6] = contextOf(mandate);

        bool ok;
        try verifier.verify(proof, pub) returns (bool v) {
            ok = v;
        } catch {
            ok = false;
        }
        if (!ok) revert InvalidProof();

        address principal = m.principal;
        if (escrowOf[principal] < amount) revert InsufficientEscrow();

        // Effects before the external transfer.
        m.head = newHead;
        escrowOf[principal] -= amount;
        if (!token.transfer(payee, amount)) revert TransferFailed();

        emit Paid(mandate, payee, amount, newHead);
    }
}
