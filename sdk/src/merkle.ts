// Fixed-depth Poseidon2 Merkle tree over payee addresses. Empty leaves are 0,
// so the root hides how many payees the mandate allows (up to 2^DEPTH).
import { leafHash, nodeHash } from "./hash.js";

export const DEPTH = 8;
export const MAX_PAYEES = 1 << DEPTH;

export const addressToField = (addr: string): bigint => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) throw new Error(`bad address: ${addr}`);
  return BigInt(addr);
};

export class Allowlist {
  readonly payees: string[];
  readonly levels: bigint[][];

  constructor(payees: string[]) {
    if (payees.length === 0) throw new Error("allowlist cannot be empty");
    if (payees.length > MAX_PAYEES) throw new Error(`allowlist holds at most ${MAX_PAYEES} payees`);
    const norm = payees.map((p) => p.toLowerCase());
    if (new Set(norm).size !== norm.length) throw new Error("duplicate payee");
    this.payees = norm;
    let level: bigint[] = new Array(MAX_PAYEES).fill(0n);
    norm.forEach((p, i) => (level[i] = leafHash(addressToField(p))));
    this.levels = [level];
    for (let d = 0; d < DEPTH; d++) {
      const next: bigint[] = [];
      for (let i = 0; i < level.length; i += 2) {
        const l = level[i],
          r = level[i + 1];
        next.push(nodeHash(l, r));
      }
      this.levels.push(next);
      level = next;
    }
  }

  get root(): bigint {
    return this.levels[DEPTH][0];
  }

  indexOf(payee: string): number {
    return this.payees.indexOf(payee.toLowerCase());
  }

  path(index: number): bigint[] {
    const out: bigint[] = [];
    let i = index;
    for (let d = 0; d < DEPTH; d++) {
      out.push(this.levels[d][i ^ 1]);
      i >>= 1;
    }
    return out;
  }
}
