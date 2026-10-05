# zkmandate

**An AI agent proves each payment fits its spending mandate, without revealing the mandate.**

The principal sets a per-tx cap, a cumulative cap, a payee allowlist (up to 256 payees)
and an expiry. Only a Poseidon2 commitment to those terms goes on-chain. Escrowed tokens
move only when the agent supplies a Noir/UltraHonk proof that the payment fits the hidden
terms. For teams that run agents with budgets they don't want competitors reading.

> **Not audited. Testnet and local use only.** Built on Noir `1.0.0-beta.19` and a
> Barretenberg `4.0.0` nightly, with a generated Solidity verifier. Read
> [SECURITY.md](https://github.com/agnij-dutta/zkmandate/blob/main/SECURITY.md) before trusting it with anything.

This is the TypeScript prover SDK. The circuit, the Solidity registry, the design and the full security model live in the main repository: https://github.com/agnij-dutta/zkmandate

## Install

```sh
npm install zkmandate
```

## Usage

```ts
import { createMandate, initialState, proveMandatePayment, payArgs, MandateViolation, toHex32 } from "zkmandate";

// Principal: write the mandate. Only the commitment and the initial head go on-chain.
const mandate = await createMandate({
  maxPerTx: 5_000_000n, totalCap: 12_000_000n,          // token base units (USDC: 6 decimals)
  notAfter: BigInt(Math.floor(Date.now() / 1000) + 7 * 86400),
  payees: [WEATHER_API, GPU_RENTAL, SEARCH_API],
});
let state = initialState(mandate);
await registry.write.createMandate([toHex32(mandate.commitment), toHex32(state.head), agentAddress]);
// Hand `mandate` (it contains the salt) to the agent over a private channel.

// Agent: prove, pay, advance.
const domain = { chainId, registry: registryAddress, principal: principalAddress };
try {
  const p = await proveMandatePayment(mandate, state, { amount: 4_000_000n, payee: WEATHER_API, validUntil, domain });
  await registry.write.pay(payArgs(p));
  state = p.newState;
} catch (e) {
  if (e instanceof MandateViolation) console.log("refused:", e.reason);
}
```

| export | what it does |
|---|---|
| `createMandate(terms)` | Builds the allowlist tree and the commitment. `terms`: `maxPerTx`, `totalCap`, `notAfter` (u64), `payees` (1 to 256 addresses), optional `salt` (must be >= 2^128; omit it to get 248 CSPRNG bits). |
| `initialState(mandate)` | State with `spent = 0`; its `head` is what `createMandate` stores. |
| `nextState(mandate, state, payment)` | Successor state without proving (bookkeeping, recovery). |
| `contextFor(domain, commitment)` | Mirrors `PrivateMandateRegistry.contextOf(principal, commitment)`. |
| `ZkMandateProver.create({ backend?, threads? })` | Long-lived prover. `backend`: `BackendType.Wasm` (default, in-process) or `BackendType.NativeUnixSocket` (native bb). |
| `prover.prove(mandate, state, payment)` | Returns `PaymentProof`: `proof`, `proofHex`, `publicInputs` (7, circuit order), `newState`, `args`, `timings`. Throws `MandateViolation` if no proof can exist. |
| `prover.verify(proof)` / `prover.destroy()` | Off-chain verification (same ZK/keccak settings as the Solidity verifier); release the backend. |
| `proveMandatePayment(...)` / `shutdown()` | Same as `prove` with a shared lazily created Wasm prover, and its cleanup. |
| `payArgs(proof)` | `pay()` arguments in ABI order. |
| `MandateViolation.reason` | `OVER_PER_TX`, `OVER_CUMULATIVE`, `EXPIRED`, `PAYEE_NOT_ALLOWED`, `ZERO_AMOUNT`, `BAD_STATE`, `UNKNOWN`. |
| `Allowlist`, `DEPTH`, `MAX_PAYEES`, hashing helpers, `TAG`, `FIELD_MODULUS`, `MIN_SALT`, `U64_MAX` | Lower-level building blocks; they match the circuit bit for bit. |

`Payment` is `{ amount, payee, validUntil, domain }`. Pick a short `validUntil` (say now
plus 10 minutes): it leaks only that the mandate does not expire before then.


## License

MIT. Copyright (c) 2026 Agnij Dutta.
