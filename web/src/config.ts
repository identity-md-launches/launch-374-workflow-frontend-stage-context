import { createPublicClient, custom, defineChain, encodeAbiParameters, fallback, http, isAddress, keccak256, toHex, type Abi, type Address, type EIP1193Provider } from 'viem';

export type Provider = EIP1193Provider & { on?: (event: string, handler: (...args: any[]) => void) => void; removeListener?: (event: string, handler: (...args: any[]) => void) => void };
declare global { interface Window { ethereum?: Provider } }
export type Deployment = {
  version: number; launchId: string; chainId: number; sourceCommit: string; attestationHash: string;
  contracts: { name: string; address: Address; abiHash: string; abiPath: string }[];
  network: { chainId: number; name: string; testnet: boolean; rpcUrls: string[]; explorer: string; nativeCurrency: { name: string; symbol: string; decimals: number }; faucets: string[]; uniswapV4: { poolManager: Address; stateView: Address; quoter: Address; universalRouter: Address; permit2: Address; positionManager: Address } };
  walletAddChain: { chainId: `0x${string}`; chainName: string; rpcUrls: string[]; nativeCurrency: { name: string; symbol: string; decimals: number }; blockExplorerUrls: string[] };
  pool: { pairedCurrency: Address; fee: number; tickSpacing: number; initialPrice: string };
  deploymentBlock: number;
  execution: { kind: string; router: Address; abiPath: string; stateViewAbiPath: string; quoterAbiPath: string };
  assets: { path: string; sha256: string }[];
};
export const poolComponents = [
  { name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' },
  { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' },
] as const;
const canonical = (x: unknown): string => JSON.stringify(order(x));
function order(x: unknown): unknown {
  if (Array.isArray(x)) return x.map(order);
  if (x && typeof x === 'object') return Object.fromEntries(Object.entries(x).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, v]) => [k, order(v)]));
  return x;
}
function localPath(path: string) {
  if (!/^[a-zA-Z0-9_./-]+$/.test(path) || path.startsWith('/') || path.split('/').some(p => p === '..' || p === '.')) throw new Error('Unsafe deployment asset path.');
  return new URL(path, new URL('./', window.location.href));
}
async function json(path: string) {
  const response = await fetch(localPath(path), { cache: 'no-cache' });
  if (!response.ok) throw new Error(`Could not load ${path}. Reload or check your connection.`);
  return response.json();
}
export async function loadConfig() {
  const deployment: Deployment = await json('imd-deployment.json');
  const d = deployment;
  if (d.version !== 1 || d.chainId !== d.network.chainId || Number(d.walletAddChain.chainId) !== d.chainId || d.execution.kind !== 'PoolSwapTest') throw new Error('Deployment configuration is inconsistent.');
  if (d.pool.pairedCurrency !== '0x0000000000000000000000000000000000000000') throw new Error('This receipt interface requires the attested native ETH pool.');
  for (const address of [...d.contracts.map(c => c.address), ...Object.values(d.network.uniswapV4), d.execution.router]) if (!isAddress(address)) throw new Error('Invalid deployment address.');
  const abis: Record<string, Abi> = {};
  await Promise.all(d.contracts.map(async c => {
    const abi = await json(c.abiPath);
    if (!Array.isArray(abi) || keccak256(toHex(canonical(abi))).slice(2) !== c.abiHash) throw new Error(`${c.name} ABI failed attestation hash verification.`);
    abis[c.name] = abi;
  }));
  const protocolPaths = { router: d.execution.abiPath, stateView: d.execution.stateViewAbiPath, quoter: d.execution.quoterAbiPath };
  await Promise.all(Object.entries(protocolPaths).map(async ([name, path]) => {
    const abi = await json(path);
    if (!Array.isArray(abi)) throw new Error(`Invalid ${name} ABI.`);
    abis[name] = abi;
  }));
  const contract = (name: string) => {
    const c = d.contracts.find(c => c.name === name);
    if (!c || !abis[name]) throw new Error(`Missing ${name} in the handoff.`);
    return { address: c.address, abi: abis[name] };
  };
  const token = contract('RCPT');
  const hook = contract('SwapReceiptHook');
  const poolKey = { currency0: d.pool.pairedCurrency as Address, currency1: token.address, fee: d.pool.fee, tickSpacing: d.pool.tickSpacing, hooks: hook.address };
  const poolId = keccak256(encodeAbiParameters([{ type: 'tuple', components: poolComponents }], [poolKey]));
  const chain = defineChain({ id: d.chainId, name: d.network.name, nativeCurrency: d.network.nativeCurrency, rpcUrls: { default: { http: d.network.rpcUrls } }, blockExplorers: { default: { name: 'Explorer', url: d.network.explorer } }, testnet: d.network.testnet });
  return { deployment, abis, token, hook, poolKey, poolId, chain };
}
export type Config = Awaited<ReturnType<typeof loadConfig>>;
export function makeClient(c: Config, provider?: Provider) {
  const transports = c.deployment.network.rpcUrls.map(url => http(url, { timeout: 9000, retryCount: 0 }));
  return createPublicClient({ chain: c.chain, transport: fallback([...transports, ...(provider ? [custom(provider, { retryCount: 0 })] : [])], { retryCount: 0 }) });
}
export type Client = ReturnType<typeof makeClient>;
