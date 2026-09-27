import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { abiHash, readJSON } from './shared.mjs';
const handoff = readJSON('deployment.json');
const net = readJSON('network.json');
assert.equal(handoff.chainId, net.network.chainId);
assert.equal(Number(net.walletAddChain.chainId), handoff.chainId);
mkdirSync('public/abi', { recursive: true });
for (const contract of handoff.contracts) {
  assert.match(contract.name, /^[A-Za-z0-9_]+$/);
  const bytes = execFileSync('git', ['show', `${handoff.sourceCommit}:docs/abi/${contract.name}.json`]);
  const abi = JSON.parse(bytes.toString());
  assert.ok(Array.isArray(abi));
  assert.equal(abiHash(abi), contract.abiHash, `${contract.name} ABI differs from attestation`);
  writeFileSync(`public/abi/${contract.name}.json`, bytes);
  console.log(`${contract.name}: pinned ABI verified (${contract.abiHash})`);
}
