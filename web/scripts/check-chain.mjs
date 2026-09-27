import { createPublicClient, http, encodeAbiParameters, keccak256 } from 'viem';
import { writeFileSync } from 'node:fs';
import { readJSON } from './shared.mjs';
const d = readJSON('../dist/imd-deployment.json');
const token = d.contracts.find(c => c.name === 'RCPT');
const hook = d.contracts.find(c => c.name === 'SwapReceiptHook');
const pool = { currency0: d.pool.pairedCurrency, currency1: token.address, fee: d.pool.fee, tickSpacing: d.pool.tickSpacing, hooks: hook.address };
const components = ['address currency0', 'address currency1', 'uint24 fee', 'int24 tickSpacing', 'address hooks'].map(s => { const [type, name] = s.split(' '); return { type, name }; });
const poolId = keccak256(encodeAbiParameters([{ type: 'tuple', components }], [pool]));
const abi = c => readJSON(`../dist/${c}`);
const report = { checkedAt: new Date().toISOString(), broadcast: false, poolId, rpc: [] };
for (const url of d.network.rpcUrls) {
  const row = { url }; report.rpc.push(row);
  const client = createPublicClient({ transport: http(url, { timeout: 12000, retryCount: 0 }) });
  try {
    row.chainId = await client.getChainId();
    if (row.chainId !== d.chainId) throw new Error('Wrong RPC chain');
    row.block = (await client.getBlockNumber()).toString();
    const addresses = Object.fromEntries([...d.contracts.map(c => [c.name, c.address]), ['PoolSwapTest', d.execution.router], ['PoolManager', d.network.uniswapV4.poolManager], ['StateView', d.network.uniswapV4.stateView], ['Quoter', d.network.uniswapV4.quoter]]);
    row.codeBytes = Object.fromEntries(await Promise.all(Object.entries(addresses).map(async ([name, address]) => [name, ((await client.getCode({ address }))?.length - 2) / 2])));
    if (Object.values(row.codeBytes).some(n => !n)) throw new Error('Empty contract code');
    row.routerManager = await client.readContract({ address: d.execution.router, abi: abi(d.execution.abiPath), functionName: 'manager' });
    row.hookManager = await client.readContract({ address: hook.address, abi: abi(hook.abiPath), functionName: 'poolManager' });
    if (![row.routerManager, row.hookManager].every(m => m.toLowerCase() === d.network.uniswapV4.poolManager.toLowerCase())) throw new Error('Manager mismatch');
    row.slot0 = (await client.readContract({ address: d.network.uniswapV4.stateView, abi: abi(d.execution.stateViewAbiPath), functionName: 'getSlot0', args: [poolId] })).map(String);
    row.totalMinted = String(await client.readContract({ address: hook.address, abi: abi(hook.abiPath), functionName: 'totalMinted' }));
    row.result = 'PASS';
    break;
  } catch (error) { row.result = 'UNAVAILABLE'; row.error = error.shortMessage ?? error.message; }
}
writeFileSync('../docs/evidence/live-chain.json', JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
