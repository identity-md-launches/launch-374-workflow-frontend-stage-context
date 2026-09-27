import assert from 'node:assert/strict';
import { readFileSync, readdirSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { abiHash, readJSON } from './shared.mjs';
const m = readJSON('../dist/imd-deployment.json'), d = readJSON('deployment.json'), n = readJSON('network.json');
assert.equal(m.version, 1);
for (const key of ['launchId', 'chainId', 'sourceCommit', 'attestationHash']) assert.equal(m[key], d[key]);
assert.deepEqual(m.network, n.network);
assert.deepEqual(m.walletAddChain, n.walletAddChain);
assert.deepEqual(m.contracts.map(({ abiPath, ...c }) => c), d.contracts.map(({ name, address, abiHash }) => ({ name, address, abiHash })));
const walk = (root, prefix = '') => readdirSync(root).flatMap(name => {
  const path = `${root}/${name}`, relative = `${prefix}${name}`, s = lstatSync(path);
  assert.ok(!s.isSymbolicLink(), `Symlink not allowed: ${path}`);
  return s.isDirectory() ? walk(path, `${relative}/`) : [relative];
});
const files = walk('../dist').filter(p => p !== 'imd-deployment.json').sort();
assert.deepEqual(m.assets.map(a => a.path).sort(), files);
assert.ok(m.assets.length <= 128);
let bytes = readFileSync('../dist/imd-deployment.json').length;
for (const asset of m.assets) {
  assert.ok(!asset.path.startsWith('/') && !asset.path.includes('..') && !asset.path.includes(':'));
  const data = readFileSync(`../dist/${asset.path}`); bytes += data.length;
  assert.ok(data.length <= 8388608);
  assert.equal(createHash('sha256').update(data).digest('hex'), asset.sha256);
}
for (const contract of m.contracts) {
  const bytes = readFileSync(`../dist/${contract.abiPath}`);
  assert.equal(abiHash(JSON.parse(bytes)), contract.abiHash);
  assert.deepEqual(bytes, execFileSync('git', ['show', `${d.sourceCommit}:docs/abi/${contract.name}.json`]));
}
assert.ok(bytes < 8 * 1024 * 1024);
assert.ok(!/\b(?:src|href)="\/(?!\/)/.test(readFileSync('../dist/index.html', 'utf8')));
console.log(JSON.stringify({ result: 'PASS', assets: m.assets.length, exportBytes: bytes, sourceCommit: m.sourceCommit, checks: ['exact handoff', 'unchanged network and walletAddChain', 'pinned raw ABI bytes and canonical Keccak', 'complete SHA-256 inventory', 'relative entrypoint assets', 'asset count and byte limits', 'no symlinks'] }, null, 2));
