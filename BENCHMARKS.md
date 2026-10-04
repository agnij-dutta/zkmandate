# Benchmarks

All numbers below are real measurements, not estimates or simulations.

## Machine and method

- **When:** 2026-10-04.
- **Machine:** Apple M4 MacBook, 10 cores, 16 GB RAM, macOS 27.0, used
  normally (load average about 2.7 from other processes during the run). Not a quiet
  lab box.
- **Toolchain:** `nargo 1.0.0-beta.19`, `bb 4.0.0-nightly.20260120`,
  `@noir-lang/noir_js 1.0.0-beta.19`, `@aztec/bb.js 4.0.0-nightly.20260120`, Node 22.14,
  solc 0.8.27 (optimizer, runs = 1), Foundry 1.5.1, anvil (cancun).
- **Proof system:** UltraHonk, **zero-knowledge** EVM flavor (`-t evm` /
  `verifierTarget: "evm"`: keccak transcript, ZK masking). The non-ZK flavor is a bit
  cheaper but can leak witness information, which defeats the point here.
- **Statement:** one payment of 4 USDC to the first of 3 allowlisted payees, from
  `spent = 0`.
- **Timing:** medians of 10 runs after one warm-up proof. In-Node timings come from
  `performance.now()` around `noir.execute` (witness) and `backend.generateProof`
  (prove). Native CLI timings are wall clock including process start and SRS load.
- **Gas:** real transactions on a local anvil node (`gasUsed` from receipts), plus
  execution-only gas measured inside `forge test`.

Timings are sensitive to machine load. An earlier run on the same laptop while it was
heavily loaded gave medians about 4x slower (Wasm 1,029 ms, native socket 458 ms, native
CLI about 500 ms). Treat the numbers as an order of magnitude, and rerun them on your box.

## Circuit size

| metric | value |
|---|---|
| ACIR opcodes | **160** |
| UltraHonk gates (`bb gates`) | **6,730** |
| Proving trace (padded) | 2^13 = 8,192 rows |
| Poseidon2 hashes per proof | 13 (mandate opening, payee leaf, 8 Merkle nodes, old + new state, next-salt derivation) |
| Allowlist capacity | 256 payees (Merkle depth 8) |
| Public inputs | 7 (plus 16 pairing-point limbs carried inside the proof) |

## Proving (one payment)

| prover | prove (median) | min / max | verify off-chain (median) | notes |
|---|---|---|---|---|
| native `bb prove` CLI | **128 ms** wall | 127 / 131 ms | 34 ms | includes process start + SRS load; peak RSS **28 MB** (`/usr/bin/time -l`) |
| bb.js, native socket backend (in Node) | **112 ms** | 109 / 143 ms | 21 ms | bb.js drives the bundled native `bb` |
| bb.js, Wasm in-process (in Node) | **270 ms** | 213 / 433 ms | 55 ms | pure WASM, what a browser or edge agent gets |
| bb.js, WasmWorker, 10 threads | 218 ms | 214 / 238 ms | 49 ms | little gain at 2^13 rows |

Witness generation (noir_js `execute`): **1 to 4 ms**. One-time prover init: about 0.7 s
for Wasm (module + SRS), about 2 ms for the native socket.

## Proof size

| | bytes |
|---|---|
| proof | **7,872** (246 field elements) |
| public inputs | 224 (7 x 32) |

## Gas (anvil, cancun)

| operation | gas |
|---|---|
| `HonkVerifier.verify` (`eth_estimateGas`, full tx incl. calldata) | **2,448,031** |
| `PrivateMandateRegistry.pay` (verify + state update + USDC transfer, full tx) | **2,504,206** to 2,504,302 |
| `pay` execution only (forge, warm verifier) | 2,359,677 |
| `verify` execution only (forge) | 2,309,187 |
| `createMandate` | 70,573 |
| deploy `ZKTranscriptLib` (linked library) | 1,331,348 |
| deploy `HonkVerifier` | 5,180,137 |
| deploy `PrivateMandateRegistry` | 928,351 |

Contract sizes: `HonkVerifier` 23,716 bytes (fits EIP-170 only with optimizer runs = 1;
runs = 200 goes over the limit), registry 3,907 bytes.

So the privacy premium is about **2.4M gas per payment** over a plain transfer. That is
fine on an L2 or an Avalanche-style C-chain and too expensive for routine L1 mainnet use.
Batching / recursive aggregation (see the README roadmap) is how to amortize it.

## Reproduce

```bash
./scripts/build.sh                            # circuit -> vk -> Solidity verifier -> forge build
(cd sdk && RUNS=10 npm run bench)             # bb.js timings + anvil gas, writes sdk/bench-results.json and circuits/Prover.toml
RUNS=10 ./scripts/bench-native.sh             # native bb CLI on the same witness
(cd contracts && forge test --mt test_Gas -vv) # execution-only gas
```

Raw output of the bb.js / gas run: [`sdk/bench-results.json`](sdk/bench-results.json).
