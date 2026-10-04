// Local-chain helpers for the demo and gas benchmarks: spawn anvil and deploy
// MockUSDC + HonkVerifier (+ its linked transcript library) + PrivateMandateRegistry
// from the Foundry build output (`forge build` in ../contracts first).
import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, type Abi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const OUT = new URL("../../contracts/out/", import.meta.url);

// anvil's default dev keys (public, test-only).
export const KEYS = {
  principal: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  agent: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
} as const;

interface Artifact {
  abi: Abi;
  bytecode: { object: Hex; linkReferences: Record<string, Record<string, { start: number; length: number }[]>> };
}

export function artifact(file: string, name: string): Artifact {
  return JSON.parse(readFileSync(new URL(`${file}/${name}.json`, OUT), "utf8"));
}

function link(a: Artifact, libs: Record<string, Address>): Hex {
  let code = a.bytecode.object.slice(2);
  for (const byFile of Object.values(a.bytecode.linkReferences)) {
    for (const [lib, refs] of Object.entries(byFile)) {
      const addr = libs[lib];
      if (!addr) throw new Error(`missing library ${lib}`);
      for (const { start, length } of refs) {
        code = code.slice(0, start * 2) + addr.slice(2).toLowerCase() + code.slice((start + length) * 2);
      }
    }
  }
  return `0x${code}`;
}

export async function startAnvil(
  port = 8545 + Math.floor(Math.random() * 1000),
): Promise<{ rpc: string; proc: ChildProcess }> {
  const proc = spawn("anvil", ["--port", String(port), "--silent", "--code-size-limit", "24576"], { stdio: "ignore" });
  const rpc = `http://127.0.0.1:${port}`;
  const client = createPublicClient({ chain: foundry, transport: http(rpc) });
  for (let i = 0; i < 50; i++) {
    try {
      await client.getChainId();
      return { rpc, proc };
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  proc.kill();
  throw new Error("anvil did not start (is Foundry installed?)");
}

export async function deployStack(rpc: string) {
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) });
  const principal = createWalletClient({
    account: privateKeyToAccount(KEYS.principal),
    chain: foundry,
    transport: http(rpc),
  });
  const agent = createWalletClient({ account: privateKeyToAccount(KEYS.agent), chain: foundry, transport: http(rpc) });

  async function deploy(a: Artifact, bytecode: Hex, args: unknown[] = []) {
    const hash = await principal.deployContract({ abi: a.abi, bytecode, args });
    const r = await pub.waitForTransactionReceipt({ hash });
    return { address: r.contractAddress as Address, gas: r.gasUsed };
  }

  const usdcA = artifact("MockUSDC.sol", "MockUSDC");
  const libA = artifact("HonkVerifier.sol", "ZKTranscriptLib");
  const verA = artifact("HonkVerifier.sol", "HonkVerifier");
  const regA = artifact("PrivateMandateRegistry.sol", "PrivateMandateRegistry");

  const usdc = await deploy(usdcA, usdcA.bytecode.object);
  const lib = await deploy(libA, libA.bytecode.object);
  const verifier = await deploy(verA, link(verA, { ZKTranscriptLib: lib.address }));
  const registry = await deploy(regA, regA.bytecode.object, [verifier.address, usdc.address]);

  return {
    pub,
    principal,
    agent,
    usdc: { ...usdc, abi: usdcA.abi },
    verifier: { ...verifier, abi: verA.abi },
    registry: { ...registry, abi: regA.abi },
    deployGas: { transcriptLib: lib.gas, verifier: verifier.gas, registry: registry.gas },
  };
}
