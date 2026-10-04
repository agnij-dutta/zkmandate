// Benchmarks: in-node bb.js proving (Wasm and native-socket backends), proof
// size, and real on-chain gas on anvil. Also writes circuits/Prover.toml so
// scripts/bench-native.sh can time the native `bb` CLI on the same witness.
//
//   cd contracts && forge build && cd ../sdk && npm run bench
import { writeFileSync } from "node:fs";
import { encodeFunctionData, type Hex } from "viem";
import {
  createMandate,
  initialState,
  contextFor,
  ZkMandateProver,
  BackendType,
  toHex32,
  addressToField,
  type Mandate,
  type MandateState,
  type Payment,
} from "../src/index.js";
import { startAnvil, deployStack } from "./chain.js";

const RUNS = Number(process.env.RUNS ?? 10);
const PAYEES = [
  "0x1111111111111111111111111111111111111111",
  "0x2222222222222222222222222222222222222222",
  "0x3333333333333333333333333333333333333333",
];

const stats = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const med = s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
  return { median: Math.round(med), min: Math.round(s[0]), max: Math.round(s[s.length - 1]), runs: s.length };
};

async function benchBackend(label: string, backend: BackendType, m: Mandate, s0: MandateState, pay: Payment, threads?: number) {
  const t0 = performance.now();
  const prover = await ZkMandateProver.create({ backend, threads });
  const initMs = performance.now() - t0;
  await prover.prove(m, s0, pay); // warm-up (SRS load, key construction)
  const witness: number[] = [];
  const prove: number[] = [];
  const verify: number[] = [];
  let bytes = 0;
  for (let i = 0; i < RUNS; i++) {
    const p = await prover.prove(m, s0, pay);
    witness.push(p.timings.witnessMs);
    prove.push(p.timings.proveMs);
    const v0 = performance.now();
    if (!(await prover.verify(p))) throw new Error("verify failed");
    verify.push(performance.now() - v0);
    bytes = p.proof.length;
  }
  await prover.destroy();
  const r = { label, initMs: Math.round(initMs), witness: stats(witness), prove: stats(prove), verify: stats(verify), proofBytes: bytes };
  console.log(JSON.stringify(r));
  return r;
}

const { rpc, proc } = await startAnvil();
try {
  const chain = await deployStack(rpc);
  const now = (await chain.pub.getBlock()).timestamp;
  const m = await createMandate({ maxPerTx: 5_000_000n, totalCap: 12_000_000n, notAfter: now + 86400n, payees: PAYEES });
  const s0 = initialState(m);
  const context = contextFor(31337n, chain.registry.address, m.commitment);
  const pay: Payment = { amount: 4_000_000n, payee: PAYEES[0], validUntil: now + 3600n, context };

  // Witness for the native CLI benchmark (same circuit, same statement shape).
  const idx = m.allowlist.indexOf(pay.payee);
  const next = await (async () => (await import("../src/index.js")).nextState(m, s0, pay))();
  const q = (x: bigint) => `"${toHex32(x)}"`;
  writeFileSync(
    new URL("../../circuits/Prover.toml", import.meta.url),
    [
      `mandate = ${q(m.commitment)}`,
      `old_state = ${q(s0.head)}`,
      `new_state = ${q(next.head)}`,
      `amount = "${pay.amount}"`,
      `payee = ${q(addressToField(pay.payee))}`,
      `valid_until = "${pay.validUntil}"`,
      `context = ${q(context)}`,
      `max_per_tx = "${m.maxPerTx}"`,
      `total_cap = "${m.totalCap}"`,
      `not_after = "${m.notAfter}"`,
      `allowlist_root = ${q(m.allowlist.root)}`,
      `salt = ${q(m.salt)}`,
      `spent = "0"`,
      `state_salt = ${q(s0.stateSalt)}`,
      `payee_index = "${idx}"`,
      `payee_path = [${m.allowlist.path(idx).map(q).join(", ")}]`,
      "",
    ].join("\n"),
  );

  const results = [];
  results.push(await benchBackend("bb.js Wasm (in-process, no workers)", BackendType.Wasm, m, s0, pay));
  try {
    const threads = (await import("node:os")).availableParallelism();
    results.push(await benchBackend(`bb.js WasmWorker (${threads} threads)`, BackendType.WasmWorker, m, s0, pay, threads));
  } catch (e) {
    console.log(`wasm worker backend unavailable: ${(e as Error).message}`);
  }
  try {
    results.push(await benchBackend("bb.js NativeUnixSocket", BackendType.NativeUnixSocket, m, s0, pay));
  } catch (e) {
    console.log(`native socket backend unavailable: ${(e as Error).message}`);
  }

  // On-chain gas: fund, create the mandate, then pay three times.
  const send = async (w: typeof chain.principal, to: { address: Hex; abi: any }, functionName: string, args: unknown[]) => {
    const hash = await w.writeContract({ ...to, functionName, args, account: w.account!, chain: w.chain });
    return chain.pub.waitForTransactionReceipt({ hash });
  };
  const reg = { address: chain.registry.address, abi: chain.registry.abi };
  await send(chain.principal, chain.usdc, "mint", [chain.principal.account!.address, 100_000_000n]);
  await send(chain.principal, chain.usdc, "approve", [reg.address, 2n ** 256n - 1n]);
  await send(chain.principal, reg, "deposit", [50_000_000n]);
  const create = await send(chain.principal, reg, "createMandate", [toHex32(m.commitment), toHex32(s0.head), chain.agent.account!.address]);

  const prover = await ZkMandateProver.create();
  let s = s0;
  const payGas: bigint[] = [];
  let verifyGas = 0n;
  for (const [i, amount] of [4_000_000n, 4_000_000n, 3_000_000n].entries()) {
    const p = await prover.prove(m, s, { ...pay, amount, payee: PAYEES[i] });
    if (i === 0) {
      verifyGas = await chain.pub.estimateGas({
        to: chain.verifier.address,
        data: encodeFunctionData({ abi: chain.verifier.abi, functionName: "verify", args: [p.proofHex, p.publicInputs] }),
      });
    }
    const a = p.args;
    const r = await send(chain.agent, reg, "pay", [a.mandate, a.payee, a.amount, a.validUntil, a.newHead, a.proof]);
    payGas.push(r.gasUsed);
    s = p.newState;
  }
  await prover.destroy();

  const gas = {
    verifyTxEstimate: verifyGas.toString(),
    payTx: payGas.map(String),
    createMandateTx: create.gasUsed.toString(),
    deploy: Object.fromEntries(Object.entries(chain.deployGas).map(([k, v]) => [k, v.toString()])),
  };
  console.log(JSON.stringify({ gas }));
  writeFileSync(new URL("../bench-results.json", import.meta.url), JSON.stringify({ when: new Date().toISOString(), runs: RUNS, results, gas }, null, 2) + "\n");
} finally {
  proc.kill();
}
