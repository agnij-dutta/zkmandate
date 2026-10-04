// zkmandate SDK: an agent proves a payment fits its private spending mandate.
//
//   const m = await createMandate({ maxPerTx, totalCap, notAfter, payees });
//   let state = initialState(m);
//   const p = await proveMandatePayment(m, state, { amount, payee, validUntil, context });
//   await registry.pay(...p.args);       // on-chain
//   state = p.newState;                  // advance the private state
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Noir, type CompiledCircuit } from "@noir-lang/noir_js";
import { Barretenberg, UltraHonkBackend, BackendType } from "@aztec/bb.js";
import { encodeAbiParameters, keccak256 } from "viem";
import {
  FIELD_MODULUS,
  initHasher,
  initialStateSalt,
  mandateHash,
  nextStateSalt,
  stateHash,
  toHex32,
} from "./hash.js";
import { Allowlist, DEPTH, addressToField } from "./merkle.js";

export * from "./hash.js";
export * from "./merkle.js";

const U64_MAX = (1n << 64n) - 1n;

/** What the principal decides. Never leaves the principal and the agent. */
export interface MandateTerms {
  maxPerTx: bigint; // token base units (USDC: 6 decimals)
  totalCap: bigint;
  notAfter: bigint; // unix seconds; use U64_MAX for "no expiry"
  payees: string[]; // EVM addresses
  salt?: bigint; // hiding randomness; generated if omitted. MUST be high entropy.
}

export interface Mandate extends Required<MandateTerms> {
  allowlist: Allowlist;
  /** Poseidon2 commitment: the only thing that goes on-chain. */
  commitment: bigint;
}

/** The agent's private running state; `head` is what the registry stores. */
export interface MandateState {
  spent: bigint;
  stateSalt: bigint;
  head: bigint;
}

export interface Payment {
  amount: bigint;
  payee: string;
  /** Registry enforces block.timestamp <= validUntil; circuit enforces validUntil <= notAfter. */
  validUntil: bigint;
  /** contextFor(chainId, registry, commitment): binds the proof to one deployment. */
  context: bigint;
}

export interface PaymentProof {
  proof: Uint8Array;
  proofHex: `0x${string}`;
  /** The 7 public inputs, in circuit order, as bytes32 hex. */
  publicInputs: `0x${string}`[];
  newState: MandateState;
  /** Ready-made arguments for PrivateMandateRegistry.pay. */
  args: {
    mandate: `0x${string}`;
    payee: `0x${string}`;
    amount: bigint;
    validUntil: bigint;
    newHead: `0x${string}`;
    proof: `0x${string}`;
  };
  timings: { witnessMs: number; proveMs: number };
}

/** The circuit refused to produce a witness: the payment breaks the mandate. */
export class MandateViolation extends Error {
  constructor(
    readonly reason:
      | "OVER_PER_TX"
      | "OVER_CUMULATIVE"
      | "EXPIRED"
      | "PAYEE_NOT_ALLOWED"
      | "ZERO_AMOUNT"
      | "BAD_STATE"
      | "UNKNOWN",
    message: string,
  ) {
    super(message);
    this.name = "MandateViolation";
  }
}

const REASONS: [string, MandateViolation["reason"]][] = [
  ["over per-tx cap", "OVER_PER_TX"],
  ["over cumulative cap", "OVER_CUMULATIVE"],
  ["expired", "EXPIRED"],
  ["payee not allowed", "PAYEE_NOT_ALLOWED"],
  ["zero amount", "ZERO_AMOUNT"],
  ["state opening", "BAD_STATE"],
  ["mandate opening", "BAD_STATE"],
  ["new state", "BAD_STATE"],
];

export function randomField(): bigint {
  const b = new Uint8Array(31); // 248 bits, always < field modulus
  crypto.getRandomValues(b);
  return b.reduce((acc, x) => (acc << 8n) | BigInt(x), 0n);
}

function checkU64(name: string, v: bigint) {
  if (v < 0n || v > U64_MAX) throw new RangeError(`${name} must fit in u64`);
}

export async function createMandate(terms: MandateTerms): Promise<Mandate> {
  await initHasher();
  checkU64("maxPerTx", terms.maxPerTx);
  checkU64("totalCap", terms.totalCap);
  checkU64("notAfter", terms.notAfter);
  const salt = terms.salt ?? randomField();
  if (salt >= FIELD_MODULUS) throw new RangeError("salt must be a field element");
  const allowlist = new Allowlist(terms.payees);
  const commitment = mandateHash(terms.maxPerTx, terms.totalCap, terms.notAfter, allowlist.root, salt);
  return { ...terms, salt, payees: allowlist.payees, allowlist, commitment };
}

/** State before any payment: spent = 0 under a salt derived from the mandate salt. */
export function initialState(m: Mandate): MandateState {
  const stateSalt = initialStateSalt(m.salt);
  return { spent: 0n, stateSalt, head: stateHash(m.commitment, 0n, stateSalt) };
}

/** Mirrors PrivateMandateRegistry.contextOf. */
export function contextFor(chainId: bigint, registry: `0x${string}`, mandate: bigint): bigint {
  const enc = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "bytes32" }],
    [chainId, registry, toHex32(mandate)],
  );
  return BigInt(keccak256(enc)) >> 8n;
}

/** Successor state after `payment`, computed without proving (pure bookkeeping). */
export function nextState(m: Mandate, s: MandateState, payment: Payment): MandateState {
  const stateSalt = nextStateSalt(m.salt, s.head, payment.context);
  const spent = s.spent + payment.amount;
  return { spent, stateSalt, head: stateHash(m.commitment, spent, stateSalt) };
}

let circuitCache: CompiledCircuit | undefined;
export function loadCircuit(): CompiledCircuit {
  if (!circuitCache) {
    const here = dirname(fileURLToPath(import.meta.url));
    circuitCache = JSON.parse(readFileSync(join(here, "..", "circuit", "zkmandate.json"), "utf8"));
  }
  return circuitCache!;
}

export interface ProverOptions {
  /** bb.js backend. Wasm runs fully in-process; NativeUnixSocket shells to the bb binary. */
  backend?: BackendType;
  threads?: number;
}

export class ZkMandateProver {
  private constructor(
    private readonly api: Barretenberg,
    private readonly noir: Noir,
    private readonly backend: UltraHonkBackend,
  ) {}

  static async create(opts: ProverOptions = {}): Promise<ZkMandateProver> {
    await initHasher();
    const circuit = loadCircuit();
    const api = await Barretenberg.new({ backend: opts.backend ?? BackendType.Wasm, threads: opts.threads });
    return new ZkMandateProver(api, new Noir(circuit), new UltraHonkBackend(circuit.bytecode, api));
  }

  /** Build the witness and an EVM (keccak, zero-knowledge) UltraHonk proof. */
  async prove(m: Mandate, s: MandateState, payment: Payment): Promise<PaymentProof> {
    checkU64("amount", payment.amount);
    checkU64("validUntil", payment.validUntil);
    const index = m.allowlist.indexOf(payment.payee);
    // A payee outside the allowlist gets a dummy path; the circuit then refuses.
    const path = index >= 0 ? m.allowlist.path(index) : new Array<bigint>(DEPTH).fill(0n);
    const next = nextState(m, s, payment);

    const inputs = {
      mandate: toHex32(m.commitment),
      old_state: toHex32(s.head),
      new_state: toHex32(next.head),
      amount: payment.amount.toString(),
      payee: toHex32(addressToField(payment.payee)),
      valid_until: payment.validUntil.toString(),
      context: toHex32(payment.context),
      max_per_tx: m.maxPerTx.toString(),
      total_cap: m.totalCap.toString(),
      not_after: m.notAfter.toString(),
      allowlist_root: toHex32(m.allowlist.root),
      salt: toHex32(m.salt),
      spent: s.spent.toString(),
      state_salt: toHex32(s.stateSalt),
      payee_index: Math.max(index, 0).toString(),
      payee_path: path.map(toHex32),
    };

    const t0 = performance.now();
    let witness: Uint8Array;
    try {
      ({ witness } = await this.noir.execute(inputs));
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // u64 overflow of spent + amount is caught by the u128 widening, but an
      // amount that itself overflows u64 is rejected above; anything else is UNKNOWN.
      const hit = REASONS.find(([needle]) => msg.includes(needle));
      throw new MandateViolation(hit ? hit[1] : "UNKNOWN", `no proof: ${msg}`);
    }
    const t1 = performance.now();
    // bb.js unconditionally console.logs a line per proof; keep stdout clean.
    const log = console.log;
    console.log = () => {};
    let proof: Uint8Array, publicInputs: string[];
    try {
      ({ proof, publicInputs } = await this.backend.generateProof(witness, { verifierTarget: "evm" }));
    } finally {
      console.log = log;
    }
    const t2 = performance.now();

    const proofHex = `0x${Buffer.from(proof).toString("hex")}` as const;
    return {
      proof,
      proofHex,
      publicInputs: publicInputs.map((x) => toHex32(BigInt(x))),
      newState: next,
      args: {
        mandate: toHex32(m.commitment),
        payee: payment.payee.toLowerCase() as `0x${string}`,
        amount: payment.amount,
        validUntil: payment.validUntil,
        newHead: toHex32(next.head),
        proof: proofHex,
      },
      timings: { witnessMs: t1 - t0, proveMs: t2 - t1 },
    };
  }

  /** Off-chain verification with the same keccak/ZK settings as the Solidity verifier. */
  async verify(p: PaymentProof): Promise<boolean> {
    return this.backend.verifyProof(
      { proof: p.proof, publicInputs: p.publicInputs },
      { verifierTarget: "evm" },
    );
  }

  async destroy(): Promise<void> {
    await this.api.destroy();
  }
}

let defaultProver: Promise<ZkMandateProver> | undefined;

/**
 * Prove that `payment` fits `mandate` given the agent's private `state`.
 * Throws MandateViolation if the payment breaks any rule: no proof can exist.
 */
export async function proveMandatePayment(
  mandate: Mandate,
  state: MandateState,
  payment: Payment,
): Promise<PaymentProof> {
  defaultProver ??= ZkMandateProver.create();
  return (await defaultProver).prove(mandate, state, payment);
}

/** Release the shared prover created by proveMandatePayment. */
export async function shutdown(): Promise<void> {
  if (defaultProver) {
    await (await defaultProver).destroy();
    defaultProver = undefined;
  }
}

export { BackendType, U64_MAX };
