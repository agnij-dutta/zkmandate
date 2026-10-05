# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-04

Published to npm on 2026-10-05 as [`zkmandate`](https://www.npmjs.com/package/zkmandate)
(the `sdk/` package).

### Added

- Noir circuit proving a payment fits a private mandate: per-tx cap, cumulative cap via a
  chained spent commitment, Merkle allowlist of up to 256 payees, expiry.
- `PrivateMandateRegistry.sol` with pooled per-principal escrow and the bb-generated
  UltraHonk (ZK, keccak) Solidity verifier.
- TypeScript SDK (`createMandate`, `initialState`, `ZkMandateProver`,
  `proveMandatePayment`, `contextFor`, `payArgs`), local demo, fixtures and benchmarks.

### Security

- Mandates are keyed by `(principal, commitment)` and proofs bind the principal, so a
  front-run `createMandate` cannot squat a commitment.
- Escrow credits the received amount, tolerates no-return-value tokens and is
  reentrancy guarded.
- The SDK rejects caller-supplied salts below 2^128.
- See [SECURITY.md](SECURITY.md) for the full review notes and known limitations.

[Unreleased]: https://github.com/agnij-dutta/zkmandate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/agnij-dutta/zkmandate/releases/tag/v0.1.0
