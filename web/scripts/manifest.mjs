import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { readJSON } from './shared.mjs';
const d = readJSON('deployment.json');
const { network, walletAddChain } = readJSON('network.json');
const walk = (path = '') => readdirSync(`../dist/${path}`).sort().flatMap(name => {
  const p = path + name;
  return statSync(`../dist/${p}`).isDirectory() ? walk(p + '/') : [p];
});
const assets = walk().filter(p => p !== 'imd-deployment.json').map(path => {
  const bytes = readFileSync(`../dist/${path}`);
  assert.ok(bytes.length <= 8388608);
  return { path, sha256: createHash('sha256').update(bytes).digest('hex') };
});
assert.ok(assets.length <= 128);
const manifest = {
  version: 1, launchId: d.launchId, chainId: d.chainId, sourceCommit: d.sourceCommit,
  attestationHash: d.attestationHash,
  contracts: d.contracts.map(({ name, address, abiHash }) => ({ name, address, abiHash, abiPath: `abi/${name}.json` })),
  network, walletAddChain, pool: d.manifest.pool,
  deploymentBlock: Math.min(...d.contracts.map(c => c.blockNumber)),
  execution: readJSON('execution.json'), assets,
};
writeFileSync('../dist/imd-deployment.json', JSON.stringify(manifest, null, 2) + '\n');
console.log(`Deployment manifest emitted after export: ${assets.length} hashed assets.`);
