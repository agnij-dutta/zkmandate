// Generates contracts/test/fixtures/payments.json: real proofs the Foundry
// tests replay against the generated HonkVerifier. Re-run after any circuit change.
import { writeFileSync, mkdirSync } from "node:fs";
import {
  createMandate,
  initialState,
  ZkMandateProver,
  MandateViolation,
  toHex32,
  type MandateDomain,
} from "../src/index.js";

export const FIXTURE = {
  chainId: 31337n,
  registry: "0x00000000000000000000000000000000c0dec0de" as const,
  principal: "0x0000000000000000000000000000000000001ead" as const,
  agent: "0x000000000000000000000000000000000000a6e7",
  payees: [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333",
  ],
  maxPerTx: 5_000_000n,
  totalCap: 12_000_000n,
  notAfter: 1_900_000_000n,
  validUntil: 1_800_000_000n,
  // Fixed so the fixtures are reproducible; any real mandate uses a random salt.
  salt: 0x1f2e3d4c5b6a798817263544536271809a8b7c6d5e4f30211203f4e5d6c7b8n,
};

const prover = await ZkMandateProver.create();
const m = await createMandate({
  maxPerTx: FIXTURE.maxPerTx,
  totalCap: FIXTURE.totalCap,
  notAfter: FIXTURE.notAfter,
  payees: FIXTURE.payees,
  salt: FIXTURE.salt,
});
const domain: MandateDomain = { chainId: FIXTURE.chainId, registry: FIXTURE.registry, principal: FIXTURE.principal };
let state = initialState(m);
const initialHead = state.head;

const plan: [bigint, number][] = [
  [4_000_000n, 0],
  [4_000_000n, 1],
  [3_000_000n, 2],
];
const payments = [];
for (const [amount, who] of plan) {
  const p = await prover.prove(m, state, {
    amount,
    payee: FIXTURE.payees[who],
    validUntil: FIXTURE.validUntil,
    domain,
  });
  if (!(await prover.verify(p))) throw new Error("fixture proof failed to verify");
  payments.push({
    payee: FIXTURE.payees[who],
    amount: amount.toString(),
    newHead: toHex32(p.newState.head),
    proof: p.proofHex,
  });
  state = p.newState;
}

// The 4th payment (2 USDC: under the per-tx cap, over the remaining 1 USDC) has no proof.
try {
  await prover.prove(m, state, {
    amount: 2_000_000n,
    payee: FIXTURE.payees[0],
    validUntil: FIXTURE.validUntil,
    domain,
  });
  throw new Error("4th payment unexpectedly proved");
} catch (e) {
  if (!(e instanceof MandateViolation) || e.reason !== "OVER_CUMULATIVE") throw e;
}

const out = {
  registry: FIXTURE.registry,
  principal: FIXTURE.principal,
  agent: FIXTURE.agent,
  mandate: toHex32(m.commitment),
  initialHead: toHex32(initialHead),
  validUntil: FIXTURE.validUntil.toString(),
  payments,
};
mkdirSync(new URL("../../contracts/test/fixtures/", import.meta.url), { recursive: true });
writeFileSync(
  new URL("../../contracts/test/fixtures/payments.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log(`wrote 3 proofs (${payments[0].proof.length / 2 - 1} bytes each) for mandate ${out.mandate}`);
await prover.destroy();
