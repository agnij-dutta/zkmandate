// The agent pays three vendors privately, on a local chain. The fourth payment
// breaks the hidden cumulative cap, and the prover cannot even produce a proof.
//
//   cd contracts && forge build && cd ../sdk && npm run demo   (BACKEND=native npm run demo for native bb)
import { formatUnits, type Address, type Hex } from "viem";
import { createMandate, initialState, contextFor, ZkMandateProver, MandateViolation, toHex32, BackendType } from "../src/index.js";
import { startAnvil, deployStack } from "./chain.js";

const c = {
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  green: (s: string) => `\x1b[32m${s}\x1b[0m`,
  red: (s: string) => `\x1b[31m${s}\x1b[0m`,
  cyan: (s: string) => `\x1b[36m${s}\x1b[0m`,
  yellow: (s: string) => `\x1b[33m${s}\x1b[0m`,
};
const usd = (x: bigint) => `$${formatUnits(x, 6)}`;
const short = (h: string) => `${h.slice(0, 10)}..${h.slice(-6)}`;

const VENDORS: Record<string, Address> = {
  "weather-api": "0x1111111111111111111111111111111111111111",
  "gpu-rental": "0x2222222222222222222222222222222222222222",
  "search-api": "0x3333333333333333333333333333333333333333",
};

console.log(c.bold("\nzkmandate: private spending mandates for AI agents\n"));

const { rpc, proc } = await startAnvil();
try {
  const s = await deployStack(rpc);
  const reg = { address: s.registry.address, abi: s.registry.abi };
  const usdc = { address: s.usdc.address, abi: s.usdc.abi };

  // 1. Principal writes the mandate. These numbers never touch the chain.
  const now = (await s.pub.getBlock()).timestamp;
  const mandate = await createMandate({
    maxPerTx: 5_000_000n,
    totalCap: 12_000_000n,
    notAfter: now + 7n * 86400n,
    payees: Object.values(VENDORS),
  });
  console.log(c.dim("principal (private):"), `max ${usd(mandate.maxPerTx)}/tx, ${usd(mandate.totalCap)} total, 7 days, ${mandate.payees.length} vendors`);

  let state = initialState(mandate);
  const commitment = toHex32(mandate.commitment);
  const send = async (w: typeof s.principal, functionName: string, args: unknown[], to = reg) => {
    const hash = await w.writeContract({ ...to, functionName, args, account: w.account!, chain: w.chain });
    return s.pub.waitForTransactionReceipt({ hash });
  };
  await send(s.principal, "mint", [s.principal.account!.address, 100_000_000n], usdc);
  await send(s.principal, "approve", [reg.address, 2n ** 256n - 1n], usdc);
  await send(s.principal, "deposit", [50_000_000n]);
  await send(s.principal, "createMandate", [commitment, toHex32(state.head), s.agent.account!.address]);
  console.log(c.dim("on-chain   (public): "), `mandate ${short(commitment)}  head ${short(toHex32(state.head))}  escrow ${usd(50_000_000n)}`);
  console.log(c.dim("                      caps, expiry and vendor list: not on-chain\n"));

  const context = contextFor(BigInt(await s.pub.getChainId()), reg.address, mandate.commitment);
  // BACKEND=native uses bb.js with the native bb binary (about 2x faster than WASM).
  const prover = await ZkMandateProver.create({
    backend: process.env.BACKEND === "native" ? BackendType.NativeUnixSocket : BackendType.Wasm,
  });
  const validUntil = now + 3600n;

  const plan: [string, bigint][] = [
    ["weather-api", 4_000_000n],
    ["gpu-rental", 4_000_000n],
    ["search-api", 3_000_000n],
    ["weather-api", 2_000_000n], // 11 + 2 > 12: over the hidden cumulative cap
  ];

  for (const [i, [vendor, amount]] of plan.entries()) {
    const payee = VENDORS[vendor];
    process.stdout.write(`${c.bold(`payment ${i + 1}`)}  ${usd(amount).padEnd(6)} -> ${vendor.padEnd(12)} `);
    try {
      const p = await prover.prove(mandate, state, { amount, payee, validUntil, context });
      const a = p.args;
      const r = await send(s.agent, "pay", [a.mandate, a.payee, a.amount, a.validUntil, a.newHead, a.proof]);
      state = p.newState;
      const bal = (await s.pub.readContract({ ...usdc, functionName: "balanceOf", args: [payee] })) as bigint;
      console.log(
        c.green("PAID"),
        c.dim(`proof ${p.proof.length}B in ${Math.round(p.timings.proveMs)}ms, verified on-chain, gas ${r.gasUsed.toLocaleString("en-US")}, ${vendor} balance ${usd(bal)}`),
      );
    } catch (e) {
      if (e instanceof MandateViolation) {
        console.log(c.red("NO PROOF"), c.dim(`(${e.reason}) the circuit is unsatisfiable, nothing to submit`));
      } else throw e;
    }
  }

  // What can an observer actually learn?
  const [, , , head] = (await s.pub.readContract({ ...reg, functionName: "mandates", args: [commitment] })) as [Address, Address, boolean, Hex];
  const escrow = (await s.pub.readContract({ ...reg, functionName: "escrowOf", args: [s.principal.account!.address] })) as bigint;
  console.log(c.bold("\nwhat the chain knows"));
  console.log(`  mandate ${short(commitment)}, head ${short(head)}, principal escrow ${usd(escrow)}`);
  console.log(`  3 payments: ${["weather-api", "gpu-rental", "search-api"].join(", ")} (payee + amount are public token transfers)`);
  console.log(c.bold("what it does not know"));
  console.log("  the per-tx cap, the total cap, the expiry, the other vendors on the allowlist, how many there are");
  console.log(c.yellow("\nthe agent followed the rules. nobody had to see the rules.\n"));

  // Also try a vendor the principal never approved.
  try {
    await prover.prove(mandate, state, { amount: 1n, payee: "0x000000000000000000000000000000000000bad0", validUntil, context });
  } catch (e) {
    if (e instanceof MandateViolation) console.log(c.dim(`bonus: unknown vendor -> NO PROOF (${e.reason})\n`));
    else throw e;
  }
  await prover.destroy();
} finally {
  proc.kill();
}
