import { readFileSync } from 'node:fs';
import { keccak256, toHex } from 'viem';
export const canonical = (x) => JSON.stringify(sort(x));
function sort(x) {
  if (Array.isArray(x)) return x.map(sort);
  if (x !== null && typeof x === 'object') return Object.fromEntries(Object.keys(x).sort().map(k => [k, sort(x[k])]));
  return x;
}
export const abiHash = (abi) => keccak256(toHex(canonical(abi))).slice(2);
export const readJSON = (p) => JSON.parse(readFileSync(p, 'utf8'));
