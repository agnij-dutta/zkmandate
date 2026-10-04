#!/usr/bin/env bash
# Rebuild everything derived from the circuit: ACIR, verification key, the
# Solidity verifier, and the SDK's copy of the circuit artifact.
# After changing the circuit, also regenerate test fixtures: (cd sdk && npm run fixtures)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NARGO="${NARGO:-$HOME/.nargo/bin/nargo}"
BB="${BB:-$HOME/.bb/bb}"

cd "$ROOT/circuits"
"$NARGO" compile
"$BB" write_vk -b target/zkmandate.json -o target -t evm
"$BB" write_solidity_verifier -k target/vk -o "$ROOT/contracts/src/HonkVerifier.sol" -t evm
# The SDK only needs the ABI and bytecode. Dropping debug_symbols and file_map
# keeps local absolute paths (and source copies) out of the committed artifact.
node -e '
const fs = require("fs");
const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const { noir_version, hash, abi, bytecode } = a;
fs.writeFileSync(process.argv[2], JSON.stringify({ noir_version, hash, abi, bytecode }));
' target/zkmandate.json "$ROOT/sdk/circuit/zkmandate.json"
(cd "$ROOT/contracts" && forge build)
