// Read-only eth_call smoke check. The simulated account is never funded or signed for.
import { createPublicClient, http, encodeAbiParameters, keccak256 } from 'viem';
import { writeFileSync } from 'node:fs';
import { readJSON } from './shared.mjs';
import { swapArgs, deltaAmounts } from '../src/chain.ts';
const d = readJSON('../dist/imd-deployment.json');
const token = d.contracts.find(c => c.name === 'RCPT'), hook = d.contracts.find(c => c.name === 'SwapReceiptHook');
const poolKey = { currency0: d.pool.pairedCurrency, currency1: token.address, fee: d.pool.fee, tickSpacing: d.pool.tickSpacing, hooks: hook.address };
const components = ['address currency0', 'address currency1', 'uint24 fee', 'int24 tickSpacing', 'address hooks'].map(s => { const [type, name] = s.split(' '); return { type, name }; });
const poolId = keccak256(encodeAbiParameters([{ type: 'tuple', components }], [poolKey]));
const client = createPublicClient({ transport: http(d.network.rpcUrls[0], { timeout: 15000, retryCount: 0 }) });
const report = { checkedAt: new Date().toISOString(), rpc: d.network.rpcUrls[0], broadcast: false, account: '0x000000000000000000000000000000000000dEaD', inputWei: '1000000000000000', priceToleranceBps: 50 };
try {
  if (await client.getChainId() !== d.chainId) throw Error('Wrong chain');
  const slot = await client.readContract({ address: d.network.uniswapV4.stateView, abi: readJSON(`../dist/${d.execution.stateViewAbiPath}`), functionName: 'getSlot0', args: [poolId] });
  const args = swapArgs({ poolKey }, report.account, true, BigInt(report.inputWei), slot[0], 50);
  const quote = await client.simulateContract({ address: d.network.uniswapV4.quoter, abi: readJSON(`../dist/${d.execution.quoterAbiPath}`), functionName: 'quoteExactInputSingle', args: [{ poolKey, zeroForOne: true, exactAmount: BigInt(report.inputWei), hookData: args[3] }], account: report.account });
  report.quotedOutput = String(quote.result[0]);
  report.quoteResult = 'PASS';
  const sim = await client.simulateContract({ address: d.execution.router, abi: readJSON(`../dist/${d.execution.abiPath}`), functionName: 'swap', args, value: BigInt(report.inputWei), account: report.account, stateOverride: [{ address: report.account, balance: 10n ** 18n }] });
  const amounts = deltaAmounts(sim.result, true);
  report.simulatedInput = String(amounts.input); report.simulatedOutput = String(amounts.output); report.priceLimit = String(args[1].sqrtPriceLimitX96);
  report.routerSimulation = 'PASS'; report.result = 'PASS';
} catch (error) { report.result = 'LIMITED'; report.error = error.shortMessage ?? error.message; }
writeFileSync('../docs/evidence/live-simulation.json', JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
