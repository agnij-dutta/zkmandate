#!/usr/bin/env bash
# Runs every test suite: Noir circuit, Foundry contracts, TypeScript SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/circuits" && "${NARGO:-$HOME/.nargo/bin/nargo}" test)
(cd "$ROOT/contracts" && forge test)
(cd "$ROOT/sdk" && npm run typecheck && npm test)
