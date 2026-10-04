// Poseidon2 (BN254) hashing that matches the circuit bit for bit.
// The circuit uses noir-lang/poseidon v0.2.6 `Poseidon2::hash`, which is the
// same sponge as barretenberg's native Poseidon2 hash (IV = len << 64).
import { BarretenbergSync, BackendType } from "@aztec/bb.js";

export const FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// Domain tags. Must match circuits/src/main.nr.
export const TAG = {
  MANDATE: 1n,
  LEAF: 2n,
  NODE: 3n,
  STATE: 4n,
  SALT: 5n,
  SALT0: 6n,
} as const;

let bb: BarretenbergSync | undefined;

/** Load the WASM hasher once. Every hashing helper requires this first. */
export async function initHasher(): Promise<void> {
  if (!bb) bb = await BarretenbergSync.new({ backend: BackendType.Wasm });
}

export function toBytes32(x: bigint): Uint8Array {
  if (x < 0n || x >= FIELD_MODULUS) throw new RangeError(`not a field element: ${x}`);
  const out = new Uint8Array(32);
  let v = x;
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

export function fromBytes(b: Uint8Array): bigint {
  let v = 0n;
  for (const byte of b) v = (v << 8n) | BigInt(byte);
  return v;
}

export function toHex32(x: bigint): `0x${string}` {
  return `0x${x.toString(16).padStart(64, "0")}`;
}

export function poseidon2(inputs: bigint[]): bigint {
  if (!bb) throw new Error("call initHasher() (or ZkMandate.create()) before hashing");
  return fromBytes(bb.poseidon2Hash({ inputs: inputs.map(toBytes32) }).hash);
}

export const leafHash = (payee: bigint) => poseidon2([TAG.LEAF, payee]);
export const nodeHash = (l: bigint, r: bigint) => poseidon2([TAG.NODE, l, r]);
export const stateHash = (mandate: bigint, spent: bigint, stateSalt: bigint) =>
  poseidon2([TAG.STATE, mandate, spent, stateSalt]);
export const initialStateSalt = (salt: bigint) => poseidon2([TAG.SALT0, salt]);
export const nextStateSalt = (salt: bigint, oldState: bigint, context: bigint) =>
  poseidon2([TAG.SALT, salt, oldState, context]);
export const mandateHash = (
  maxPerTx: bigint,
  totalCap: bigint,
  notAfter: bigint,
  allowlistRoot: bigint,
  salt: bigint,
) => poseidon2([TAG.MANDATE, maxPerTx, totalCap, notAfter, allowlistRoot, salt]);
