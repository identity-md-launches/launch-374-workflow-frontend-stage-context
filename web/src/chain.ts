import { encodeAbiParameters, formatUnits, isAddressEqual, parseUnits, type Address, type Hex } from 'viem';
import type { Client, Config, Provider } from './config';
export type Receipt = { id: bigint; ethPaid: bigint; tokensReceived: bigint; token: Address; blockNumber: bigint; timestamp: bigint; image: string; owner?: Address; transactionHash?: Hex };
export const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
export function display(value: bigint, decimals = 18, maximumFractionDigits = 6) {
  const number = Number(formatUnits(value, decimals));
  return number > 0 && number < 10 ** -maximumFractionDigits
    ? number.toLocaleString('en-US', { maximumSignificantDigits: 4 })
    : number.toLocaleString('en-US', { maximumFractionDigits });
}
export function errorText(error: unknown): string {
  const e = error as { shortMessage?: string; message?: string; code?: number; cause?: { code?: number } };
  if (e?.code === 4001 || e?.cause?.code === 4001 || /rejected|denied/i.test(e?.message ?? '')) return 'Request declined in your wallet. You can try again when ready.';
  return (e?.shortMessage || e?.message || 'Request failed. Check your connection and try again.').slice(0, 400);
}
export async function verify(c: Config, client: Client) {
  if (await client.getChainId() !== c.chain.id) throw new Error('RPC returned the wrong chain. Transactions are disabled.');
  const addresses = [c.token.address, c.hook.address, c.deployment.execution.router, c.deployment.network.uniswapV4.poolManager, c.deployment.network.uniswapV4.stateView, c.deployment.network.uniswapV4.quoter];
  await Promise.all(addresses.map(async address => {
    const code = await client.getCode({ address });
    if (!code || code === '0x') throw new Error(`No deployed code at ${address}. Transactions are disabled.`);
  }));
  const [routerManager, hookManager] = await Promise.all([
    client.readContract({ address: c.deployment.execution.router, abi: c.abis.router, functionName: 'manager' }),
    client.readContract({ ...c.hook, functionName: 'poolManager' }),
  ]);
  if (![routerManager, hookManager].every(m => isAddressEqual(m as Address, c.deployment.network.uniswapV4.poolManager))) throw new Error('PoolManager binding failed. Transactions are disabled.');
}
export async function readState(c: Config, client: Client, account?: Address) {
  const [total, threshold, decimals, symbol, supply, slot, block, nativeBalance, tokenBalance, allowance] = await Promise.all([
    client.readContract({ ...c.hook, functionName: 'totalMinted' }),
    client.readContract({ ...c.hook, functionName: 'MIN_ETH_PAID' }),
    client.readContract({ ...c.token, functionName: 'decimals' }),
    client.readContract({ ...c.token, functionName: 'symbol' }),
    client.readContract({ ...c.token, functionName: 'totalSupply' }),
    client.readContract({ address: c.deployment.network.uniswapV4.stateView, abi: c.abis.stateView, functionName: 'getSlot0', args: [c.poolId] }),
    client.getBlockNumber(),
    account ? client.getBalance({ address: account }) : 0n,
    account ? client.readContract({ ...c.token, functionName: 'balanceOf', args: [account] }) : 0n,
    account ? client.readContract({ ...c.token, functionName: 'allowance', args: [account, c.deployment.execution.router] }) : 0n,
  ]);
  const sqrtPrice = (slot as [bigint, number, number, number])[0];
  return { total: total as bigint, threshold: threshold as bigint, decimals: Number(decimals), symbol: String(symbol), supply: supply as bigint, sqrtPrice, block, nativeBalance, tokenBalance: tokenBalance as bigint, allowance: allowance as bigint, at: Date.now(), price: (Number(sqrtPrice) / 2 ** 96) ** 2 * 10 ** (18 - Number(decimals)) };
}
export type State = Awaited<ReturnType<typeof readState>>;
export async function receipt(c: Config, client: Client, id: bigint): Promise<Receipt | null> {
  const r = await client.readContract({ ...c.hook, functionName: 'receiptOf', args: [id] }) as Omit<Receipt, 'id' | 'image'>;
  if (!isAddressEqual(r.token, c.token.address)) return null;
  const uri = await client.readContract({ ...c.hook, functionName: 'tokenURI', args: [id] }) as string;
  if (!uri.startsWith('data:application/json;base64,')) throw new Error(`Receipt #${id} has unsupported metadata.`);
  const metadata = JSON.parse(atob(uri.split(',')[1]));
  if (typeof metadata.image !== 'string' || !/^data:image\/svg\+xml;base64,[A-Za-z0-9+/=]+$/.test(metadata.image)) throw new Error(`Receipt #${id} has an unsupported image.`);
  return { ...r, id, blockNumber: BigInt(r.blockNumber), timestamp: BigInt(r.timestamp), image: metadata.image };
}
export async function ownerPage(c: Config, client: Client, owner: Address, offset: bigint) {
  const [ids, total] = await Promise.all([
    client.readContract({ ...c.hook, functionName: 'receiptsOf', args: [owner, offset, 12n] }) as Promise<bigint[]>,
    client.readContract({ ...c.hook, functionName: 'balanceOf', args: [owner] }) as Promise<bigint>,
  ]);
  const records = await Promise.all(ids.map(id => receipt(c, client, id)));
  return { records: records.filter((r): r is Receipt => !!r), next: offset + BigInt(ids.length), total };
}
export async function latestPage(c: Config, client: Client, cursor: bigint) {
  const ids = Array.from({ length: Number(cursor < 24n ? cursor : 24n) }, (_, i) => cursor - BigInt(i));
  const records = (await Promise.all(ids.map(id => receipt(c, client, id)))).filter((r): r is Receipt => !!r);
  // Read exact mint blocks, avoiding provider-wide log range limits and full-history scans.
  const blocks = [...new Set(records.map(r => r.blockNumber))];
  const events = (await Promise.all(blocks.map(block => client.getContractEvents({ ...c.hook, eventName: 'Receipt', fromBlock: block, toBlock: block })))).flat();
  const result = records.flatMap(r => {
    const log = events.find(log => { const a = log.args as { id: bigint; poolId: Hex }; return a.id === r.id && a.poolId.toLowerCase() === c.poolId.toLowerCase(); });
    if (!log) return [];
    return [{ ...r, owner: (log.args as { owner: Address }).owner, transactionHash: log.transactionHash! }];
  });
  return { records: result, cursor: cursor - BigInt(ids.length) };
}
export function amountValue(text: string, decimals: number) {
  if (!/^(\d+)(\.\d*)?$/.test(text) || (text.split('.')[1]?.length ?? 0) > decimals) throw new Error(`Enter a positive amount with at most ${decimals} decimals.`);
  const amount = parseUnits(text, decimals);
  if (amount <= 0n || amount >= 2n ** 127n) throw new Error('Enter an amount greater than zero and below the pool limit.');
  return amount;
}
function sqrt(n: bigint): bigint {
  if (n < 2n) return n;
  let x = n, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + n / x) / 2n; }
  return x;
}
export function swapArgs(c: Config, account: Address, buy: boolean, amount: bigint, sqrtPrice: bigint, bps: number) {
  if (!Number.isInteger(bps) || bps < 10 || bps > 500) throw new Error('Choose a price tolerance between 0.1% and 5%.');
  const squared = sqrtPrice * sqrtPrice;
  const limit = sqrt(buy ? squared * BigInt(10000 - bps) / 10000n : squared * 10000n / BigInt(10000 - bps));
  if (limit <= 4295128739n || limit >= 1461446703485210103287273052203988822378723970342n) throw new Error('Pool price is outside the supported range.');
  const hookData = encodeAbiParameters([{ type: 'address' }], [account]);
  return [c.poolKey, { zeroForOne: buy, amountSpecified: -amount, sqrtPriceLimitX96: limit }, { takeClaims: false, settleUsingBurn: false }, hookData] as const;
}
export function deltaAmounts(packed: bigint, buy: boolean) {
  const amount0 = BigInt.asIntN(128, packed >> 128n), amount1 = BigInt.asIntN(128, packed);
  const input = -(buy ? amount0 : amount1), output = buy ? amount1 : amount0;
  if (input <= 0n || output <= 0n) throw new Error('The simulation returned no usable swap. Try a smaller amount.');
  return { input, output };
}
export async function ensureWallet(provider: Provider, c: Config, expected: Address) {
  const [accounts, chain] = await Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]);
  if (Number(chain) !== c.chain.id || !accounts[0] || !isAddressEqual(accounts[0], expected)) throw new Error('Wallet changed. Reconnect and review the swap again.');
}
export async function switchChain(provider: Provider, c: Config) {
  try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: c.deployment.walletAddChain.chainId }] }); }
  catch (error) {
    const e = error as { code?: number; message?: string; data?: { originalError?: { code?: number } } };
    if (e.code !== 4902 && e.data?.originalError?.code !== 4902 && !/unknown chain|unrecognized chain|not added/i.test(e.message ?? '')) throw error;
    await provider.request({ method: 'wallet_addEthereumChain', params: [c.deployment.walletAddChain] });
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: c.deployment.walletAddChain.chainId }] });
  }
}
