import { test, after } from "node:test";
import assert from "node:assert/strict";
import {
  createMandate,
  initialState,
  initHasher,
  leafHash,
  nodeHash,
  mandateHash,
  stateHash,
  contextFor,
  ZkMandateProver,
  MandateViolation,
  type Mandate,
} from "../src/index.js";

// Vectors printed by `nargo test --show-output test_vectors_for_sdk`.
test("poseidon2 hashing matches the Noir circuit", async () => {
  await initHasher();
  assert.equal(leafHash(0xa11cen), 0x0f33e15cb965df28649b309383f5d7881dccd410431cb94654f8ebf2737d7cb6n);
  assert.equal(nodeHash(1n, 2n), 0x0fb729d8dfcb8fc31d7ac8f4091e50256621cfc9e46da3e3fbb3186772cdaceen);
  assert.equal(
    mandateHash(5_000_000n, 12_000_000n, 2_000_000_000n, 7n, 0x5a17n),
    0x0e1b75aba722c6fd01c571b37efb23bdedce6f7a48dee0ab7aaf84516c0aa66en,
  );
  assert.equal(stateHash(9n, 3n, 0x77n), 0x17f8725aecb543b0ff4ae4fb7b90e8e7ac394fd91e197ec4f8aa0dbf1f9fd4f2n);
});

const VENDOR_A = "0x00000000000000000000000000000000000a11ce";
const VENDOR_B = "0x0000000000000000000000000000000000000b0b";
const MALLORY = "0x000000000000000000000000000000000000bad0";
const REGISTRY = "0x00000000000000000000000000000000c0dec0de" as const;

let prover: ZkMandateProver;
let m: Mandate;
let ctx: bigint;

after(async () => prover && (await prover.destroy()));

test("valid payment proves, verifies, and advances the state", async () => {
  prover = await ZkMandateProver.create();
  m = await createMandate({
    maxPerTx: 5_000_000n,
    totalCap: 12_000_000n,
    notAfter: 2_000_000_000n,
    payees: [VENDOR_A, VENDOR_B],
  });
  ctx = contextFor(31337n, REGISTRY, m.commitment);
  const s0 = initialState(m);
  const p = await prover.prove(m, s0, { amount: 4_000_000n, payee: VENDOR_A, validUntil: 1_900_000_000n, context: ctx });
  assert.equal(p.publicInputs.length, 7);
  assert.equal(BigInt(p.publicInputs[1]), s0.head);
  assert.equal(BigInt(p.publicInputs[2]), p.newState.head);
  assert.equal(p.newState.spent, 4_000_000n);
  assert.ok(await prover.verify(p));

  // Tampering with a public input breaks verification.
  const forged = { ...p, publicInputs: [...p.publicInputs] };
  forged.publicInputs[3] = `0x${(40_000_000n).toString(16).padStart(64, "0")}`;
  assert.equal(await prover.verify(forged).catch(() => false), false);
});

async function expectViolation(fn: () => Promise<unknown>, reason: MandateViolation["reason"]) {
  await assert.rejects(fn, (e: unknown) => e instanceof MandateViolation && e.reason === reason);
}

test("over per-tx cap: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 5_000_001n, payee: VENDOR_A, validUntil: 1n, context: ctx }),
    "OVER_PER_TX",
  );
});

test("over cumulative cap: no proof", async () => {
  const s = { ...initialState(m) };
  const s1 = (await prover.prove(m, s, { amount: 5_000_000n, payee: VENDOR_A, validUntil: 1n, context: ctx })).newState;
  const s2 = (await prover.prove(m, s1, { amount: 5_000_000n, payee: VENDOR_B, validUntil: 1n, context: ctx })).newState;
  await expectViolation(
    () => prover.prove(m, s2, { amount: 2_000_001n, payee: VENDOR_A, validUntil: 1n, context: ctx }),
    "OVER_CUMULATIVE",
  );
});

test("payee outside the allowlist: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 1n, payee: MALLORY, validUntil: 1n, context: ctx }),
    "PAYEE_NOT_ALLOWED",
  );
});

test("validUntil past notAfter: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 1n, payee: VENDOR_A, validUntil: 2_000_000_001n, context: ctx }),
    "EXPIRED",
  );
});

test("lying about spent-so-far: no proof", async () => {
  const s = initialState(m);
  const lie = { ...s, head: stateHash(m.commitment, 9_000_000n, s.stateSalt) };
  await expectViolation(
    () => prover.prove(m, lie, { amount: 1n, payee: VENDOR_A, validUntil: 1n, context: ctx }),
    "BAD_STATE",
  );
});
