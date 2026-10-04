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
  payArgs,
  loadCircuit,
  toHex32,
  FIELD_MODULUS,
  MIN_SALT,
  ZkMandateProver,
  MandateViolation,
  type Mandate,
  type MandateDomain,
} from "../src/index.js";
import { Noir } from "@noir-lang/noir_js";

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
const DOMAIN: MandateDomain = {
  chainId: 31337n,
  registry: "0x00000000000000000000000000000000c0dec0de",
  principal: "0x0000000000000000000000000000000000001ead",
};

let prover: ZkMandateProver;
let m: Mandate;

after(async () => prover && (await prover.destroy()));

test("valid payment proves, verifies, and advances the state", async () => {
  prover = await ZkMandateProver.create();
  m = await createMandate({
    maxPerTx: 5_000_000n,
    totalCap: 12_000_000n,
    notAfter: 2_000_000_000n,
    payees: [VENDOR_A, VENDOR_B],
  });
  const s0 = initialState(m);
  const p = await prover.prove(m, s0, {
    amount: 4_000_000n,
    payee: VENDOR_A,
    validUntil: 1_900_000_000n,
    domain: DOMAIN,
  });
  assert.equal(p.publicInputs.length, 7);
  // Public input order must match PrivateMandateRegistry.pay.
  assert.equal(BigInt(p.publicInputs[0]), m.commitment);
  assert.equal(BigInt(p.publicInputs[1]), s0.head);
  assert.equal(BigInt(p.publicInputs[2]), p.newState.head);
  assert.equal(BigInt(p.publicInputs[3]), 4_000_000n);
  assert.equal(BigInt(p.publicInputs[4]), BigInt(VENDOR_A));
  assert.equal(BigInt(p.publicInputs[5]), 1_900_000_000n);
  assert.equal(BigInt(p.publicInputs[6]), contextFor(DOMAIN, m.commitment));
  assert.equal(p.newState.spent, 4_000_000n);
  assert.ok(await prover.verify(p));
  assert.deepEqual(payArgs(p), [
    DOMAIN.principal,
    toHex32(m.commitment),
    VENDOR_A,
    4_000_000n,
    1_900_000_000n,
    toHex32(p.newState.head),
    p.proofHex,
  ]);

  // Tampering with a public input breaks verification.
  const forged = { ...p, publicInputs: [...p.publicInputs] };
  forged.publicInputs[3] = `0x${40_000_000n.toString(16).padStart(64, "0")}`;
  assert.equal(await prover.verify(forged).catch(() => false), false);
});

async function expectViolation(fn: () => Promise<unknown>, reason: MandateViolation["reason"]) {
  await assert.rejects(fn, (e: unknown) => e instanceof MandateViolation && e.reason === reason);
}

test("over per-tx cap: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 5_000_001n, payee: VENDOR_A, validUntil: 1n, domain: DOMAIN }),
    "OVER_PER_TX",
  );
});

test("over cumulative cap: no proof", async () => {
  const s = { ...initialState(m) };
  const s1 = (await prover.prove(m, s, { amount: 5_000_000n, payee: VENDOR_A, validUntil: 1n, domain: DOMAIN }))
    .newState;
  const s2 = (await prover.prove(m, s1, { amount: 5_000_000n, payee: VENDOR_B, validUntil: 1n, domain: DOMAIN }))
    .newState;
  await expectViolation(
    () => prover.prove(m, s2, { amount: 2_000_001n, payee: VENDOR_A, validUntil: 1n, domain: DOMAIN }),
    "OVER_CUMULATIVE",
  );
});

test("payee outside the allowlist: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 1n, payee: MALLORY, validUntil: 1n, domain: DOMAIN }),
    "PAYEE_NOT_ALLOWED",
  );
});

test("validUntil past notAfter: no proof", async () => {
  await expectViolation(
    () => prover.prove(m, initialState(m), { amount: 1n, payee: VENDOR_A, validUntil: 2_000_000_001n, domain: DOMAIN }),
    "EXPIRED",
  );
});

test("lying about spent-so-far: no proof", async () => {
  const s = initialState(m);
  const lie = { ...s, head: stateHash(m.commitment, 9_000_000n, s.stateSalt) };
  await expectViolation(
    () => prover.prove(m, lie, { amount: 1n, payee: VENDOR_A, validUntil: 1n, domain: DOMAIN }),
    "BAD_STATE",
  );
});

test("context binds chain, registry and principal", () => {
  const base = contextFor(DOMAIN, m.commitment);
  assert.ok(base < FIELD_MODULUS);
  assert.notEqual(contextFor({ ...DOMAIN, chainId: 1n }, m.commitment), base);
  assert.notEqual(
    contextFor({ ...DOMAIN, registry: "0x00000000000000000000000000000000c0dec0df" }, m.commitment),
    base,
  );
  assert.notEqual(
    contextFor({ ...DOMAIN, principal: "0x0000000000000000000000000000000000001eae" }, m.commitment),
    base,
  );
});

test("guessable caller-supplied salts are rejected", async () => {
  const terms = { maxPerTx: 1n, totalCap: 1n, notAfter: 1n, payees: [VENDOR_A] };
  await assert.rejects(() => createMandate({ ...terms, salt: 0x5a17n }), /salt is too small/);
  await assert.rejects(() => createMandate({ ...terms, salt: MIN_SALT - 1n }), /salt is too small/);
  await assert.rejects(() => createMandate({ ...terms, salt: FIELD_MODULUS }), /field element/);
  await createMandate({ ...terms, salt: MIN_SALT });
  const auto = await createMandate(terms);
  assert.ok(auto.salt >= MIN_SALT);
});

// Field wraparound: in the field, p - 1 is "-1". If amounts were plain Field
// values, amount = p - 1 would make spent + amount wrap below the cap. The
// circuit types amount as u64, so the witness generator refuses it outright.
test("an amount of p - 1 (field wraparound) cannot be witnessed", async () => {
  const s = initialState(m);
  const noir = new Noir(loadCircuit());
  const minusOne = FIELD_MODULUS - 1n;
  const inputs = {
    mandate: toHex32(m.commitment),
    old_state: toHex32(s.head),
    new_state: toHex32(s.head),
    amount: toHex32(minusOne),
    payee: toHex32(BigInt(VENDOR_A)),
    valid_until: "1",
    context: toHex32(contextFor(DOMAIN, m.commitment)),
    max_per_tx: m.maxPerTx.toString(),
    total_cap: m.totalCap.toString(),
    not_after: m.notAfter.toString(),
    allowlist_root: toHex32(m.allowlist.root),
    salt: toHex32(m.salt),
    spent: "0",
    state_salt: toHex32(s.stateSalt),
    payee_index: "0",
    payee_path: m.allowlist.path(0).map(toHex32),
  };
  await assert.rejects(() => noir.execute(inputs), /does not fall within range/);
});
