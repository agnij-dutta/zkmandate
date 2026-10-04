# Benchmarks

Measured 2026-10-04 on an Apple M4 MacBook (10 cores, 16 GB RAM, macOS 27.0), with
other workloads running (browser, other dev processes), so treat timings as
"laptop under normal use", not a quiet lab box. Medians of 10 runs after one warm-up.

Toolchain: `nargo 1.0.0-beta.19`, `bb 4.0.0-nightly.20260120`,
`@noir-lang/noir_js 1.0.0-beta.19`, `@aztec/bb.js 4.0.0-nightly.20260120`,
solc 0.8.27 (optimizer, runs = 1), Foundry 1.5.1, anvil (cancun).

Proof system: UltraHonk, **zero-knowledge** EVM flavor (`-t evm`: keccak transcript,
ZK masking). The non-ZK flavor would be slightly cheaper but can leak witness
information, which defeats the point here.

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

| prover | prove (median) | min / max | verify off-chain | notes |
|---|---|---|---|---|
| native `bb prove` CLI | **~0.50 s** wall | 0.38 / 0.80 s | 0.09 s | includes process start + SRS load; peak RSS **28 MB** |
| bb.js, native socket backend (in Node) | **458 ms** | 386 / 788 ms | 98 ms | bb.js drives the bundled native `bb` |
| bb.js, Wasm in-process (in Node) | **1,029 ms** | 818 / 2,118 ms | 226 ms | pure WASM, what a browser/edge agent gets |
| bb.js, WasmWorker, 10 threads | 1,858 ms | 1,272 / 2,906 ms | 409 ms | slower than single Wasm: at 2^13 rows the thread overhead dominates |

Witness generation (noir_js `execute`): **4 to 8 ms**. One-time prover init: about 2 to 4 s
for Wasm (module + SRS), about 5 ms for the native socket.

An earlier run on a less loaded machine gave Wasm 941 ms and native socket 486 ms,
which is the spread to expect.

## Proof size

| | bytes |
|---|---|
| proof | **7,872** (246 field elements) |
| public inputs | 224 (7 x 32) |

## Gas (real transactions on anvil, cancun)

| operation | gas |
|---|---|
| `HonkVerifier.verify` (eth_estimateGas, full tx incl. calldata) | **2,447,983** |
| `PrivateMandateRegistry.pay` (verify + state update + USDC transfer, full tx) | **2,502,883** to 2,502,919 |
| `pay` execution only (forge, warm verifier) | 2,355,749 |
| `verify` execution only (forge) | 2,309,191 |
| `createMandate` | 92,172 |
| deploy `ZKTranscriptLib` (linked library) | 1,331,348 |
| deploy `HonkVerifier` | 5,180,137 |
| deploy `PrivateMandateRegistry` | 799,588 |

Contract sizes: `HonkVerifier` 23,716 bytes (fits EIP-170 only with optimizer runs = 1;
runs = 200 is 59 bytes over the limit for about 1% less gas), registry 3,443 bytes.

So the privacy premium is about **2.4M gas per payment** over a plain transfer. That is
fine on an L2 or Avalanche C-chain and too expensive for routine L1 mainnet use. See the
TODOs in the README (batching / aggregation) for how to amortize it.

## Reproduce

```bash
./scripts/build.sh                      # circuit -> vk -> Solidity verifier -> forge build
cd sdk && RUNS=10 npm run bench         # bb.js timings + anvil gas, writes sdk/bench-results.json
cd .. && RUNS=10 ./scripts/bench-native.sh   # native bb CLI on the same witness
cd contracts && forge test --mt test_Gas -vv # execution-only gas
```

Raw output of the latest bb.js / gas run: [`sdk/bench-results.json`](sdk/bench-results.json).
