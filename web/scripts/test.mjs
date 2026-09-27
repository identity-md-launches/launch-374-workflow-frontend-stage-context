// Production-export interaction tests. All RPC and wallet signing are mocked; nothing broadcasts.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import { decodeFunctionData, encodeFunctionResult, encodeEventTopics, encodeAbiParameters, keccak256, toHex, zeroAddress } from 'viem';
import { readJSON } from './shared.mjs';

const root = resolve('../dist'), evidence = resolve('../docs/evidence');
mkdirSync(evidence, { recursive: true });
const d = readJSON('../dist/imd-deployment.json');
const contract = name => d.contracts.find(c => c.name === name);
const token = contract('RCPT'), hook = contract('SwapReceiptHook');
const tokenABI = readJSON(`../dist/${token.abiPath}`), hookABI = readJSON(`../dist/${hook.abiPath}`);
const routerABI = readJSON(`../dist/${d.execution.abiPath}`), stateABI = readJSON(`../dist/${d.execution.stateViewAbiPath}`), quoterABI = readJSON(`../dist/${d.execution.quoterAbiPath}`);
const abis = new Map([[token.address, tokenABI], [hook.address, hookABI], [d.execution.router, routerABI], [d.network.uniswapV4.stateView, stateABI], [d.network.uniswapV4.quoter, quoterABI]]);
const account = '0x1234567890123456789012345678901234567890', secondAccount = '0x2345678901234567890123456789012345678901';
const otherToken = '0x3333333333333333333333333333333333333333';
const components = ['address currency0', 'address currency1', 'uint24 fee', 'int24 tickSpacing', 'address hooks'].map(s => { const [type, name] = s.split(' '); return { type, name }; });
const pool = { currency0: d.pool.pairedCurrency, currency1: token.address, fee: d.pool.fee, tickSpacing: d.pool.tickSpacing, hooks: hook.address };
const poolId = keccak256(encodeAbiParameters([{ type: 'tuple', components }], [pool]));
const hash = '0x' + 'ab'.repeat(32), blockHash = '0x' + 'cd'.repeat(32);
const server = createServer((req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    assert.ok(url.pathname.startsWith('/preview/'));
    const file = resolve(root, decodeURIComponent(url.pathname.slice(9) || 'index.html'));
    assert.ok(file.startsWith(root + '/'));
    const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };
    res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream' }); res.end(readFileSync(file));
  } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
const report = { testedAt: new Date().toISOString(), export: 'dist/ served under /preview/', browser: await browser.version(), liveTransactions: false, checks: [], screenshots: [], consoleErrors: [], resourceFailures: [] };
const check = (name, detail) => { report.checks.push({ name, result: 'PASS', ...(detail ? { detail } : {}) }); console.log(`PASS ${name}`); };

function fixture(options = {}) {
  const f = { allowance: 0n, total: 15n, calls: [], sent: [], rpcUrls: [], noCode: false, failSimulation: false, partial: false, rejectConnection: false, ...options };
  function data(id) { return { ethPaid: 1000000000000000n, tokensReceived: id * 100000000000000000000n, token: id === 14n ? otherToken : token.address, blockNumber: Number(BigInt(d.deploymentBlock) + id), timestamp: 1789990000 + Number(id) * 12 }; }
  function metadata(id) {
    const r = data(id);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 420"><rect width="420" height="420" rx="24" fill="#0b0d12"/><rect x="16" y="16" width="388" height="388" rx="16" fill="none" stroke="#3d7eff" stroke-width="2"/><g font-family="monospace"><text x="32" y="72" fill="white" font-size="30">Swap Receipt #${id}</text><text x="32" y="140" fill="#9db4ff" font-size="18">ETH paid</text><text x="32" y="168" fill="white" font-size="22">0.001000 ETH</text><text x="32" y="216" fill="#9db4ff" font-size="18">Tokens received</text><text x="32" y="244" fill="white" font-size="22">${id * 100n}</text><text x="32" y="292" fill="#9db4ff" font-size="18">Token</text><text x="32" y="316" fill="white" font-size="13">${token.address}</text><text x="32" y="364" fill="#9db4ff" font-size="18">Block ${r.blockNumber}</text></g></svg>`;
    return 'data:application/json;base64,' + Buffer.from(JSON.stringify({ name: `Swap Receipt #${id}`, image: 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64') })).toString('base64');
  }
  f.rpc = async (method, params = []) => {
    if (method === 'eth_chainId') return toHex(d.chainId);
    if (method === 'eth_blockNumber') return toHex(BigInt(d.deploymentBlock) + 100n);
    if (method === 'eth_getCode') return f.noCode ? '0x' : '0x6080604052';
    if (method === 'eth_getBalance') return toHex(10n ** 20n);
    if (method === 'eth_getTransactionCount') return '0x0';
    if (method === 'eth_getTransactionReceipt') return { transactionHash: hash, transactionIndex: '0x0', blockHash, blockNumber: toHex(BigInt(d.deploymentBlock) + 100n), from: account, to: d.execution.router, cumulativeGasUsed: '0x50000', gasUsed: '0x50000', contractAddress: null, logs: [], logsBloom: '0x' + '00'.repeat(256), status: '0x1', effectiveGasPrice: '0x3b9aca00', type: '0x2' };
    if (method === 'eth_getLogs') {
      const id = BigInt(params[0].fromBlock) - BigInt(d.deploymentBlock);
      if (id < 1n || id > f.total) return [];
      const record = data(id), eventPool = id === 13n ? hash : poolId;
      return [{ address: hook.address, topics: encodeEventTopics({ abi: hookABI, eventName: 'Receipt', args: { id, owner: account, poolId: eventPool } }), data: encodeAbiParameters([{ type: 'uint128' }, { type: 'uint128' }, { type: 'uint256' }], [record.ethPaid, record.tokensReceived, BigInt(record.blockNumber)]), blockNumber: toHex(record.blockNumber), transactionHash: hash, transactionIndex: '0x0', blockHash, logIndex: '0x0', removed: false }];
    }
    if (method === 'eth_call' || method === 'eth_sendTransaction') {
      const request = params[0], abi = abis.get(request.to.toLowerCase());
      assert.ok(abi, `Unexpected contract ${request.to}`);
      const decoded = decodeFunctionData({ abi, data: request.data });
      f.calls.push({ method, to: request.to.toLowerCase(), ...decoded, value: request.value });
      const { functionName: name, args = [] } = decoded;
      if (method === 'eth_sendTransaction') {
        f.sent.push({ ...decoded, to: request.to, value: request.value });
        if (name === 'approve') f.allowance = args[1];
        if (name === 'swap') f.total++;
        return hash;
      }
      let result;
      if (name === 'manager' || name === 'poolManager') result = d.network.uniswapV4.poolManager;
      else if (name === 'totalMinted') result = f.total;
      else if (name === 'MIN_ETH_PAID') result = 10n ** 15n;
      else if (name === 'decimals') result = 18;
      else if (name === 'symbol') result = 'RCPT';
      else if (name === 'totalSupply') result = 1000000000n * 10n ** 18n;
      else if (name === 'getSlot0') result = [BigInt(d.pool.initialPrice), 138180, 0, 3000];
      else if (name === 'balanceOf') result = request.to.toLowerCase() === token.address ? 100000n * 10n ** 18n : f.total;
      else if (name === 'allowance') result = f.allowance;
      else if (name === 'receiptsOf') result = Array.from({ length: Number(f.total) }, (_, i) => BigInt(i + 1)).slice(Number(args[1]), Number(args[1] + args[2]));
      else if (name === 'receiptOf') result = data(args[0]);
      else if (name === 'tokenURI') result = metadata(args[0]);
      else if (name === 'approve') result = true;
      else if (name === 'quoteExactInputSingle') result = [args[0].zeroForOne ? args[0].exactAmount * 1000000n : args[0].exactAmount / 1000000n, 350000n];
      else if (name === 'swap') {
        if (f.failSimulation) throw new Error('execution reverted: mock insufficient liquidity');
        const buy = args[1].zeroForOne, input = -args[1].amountSpecified / (f.partial ? 2n : 1n), output = buy ? input * 1000000n : input / 1000000n;
        const a0 = buy ? -input : output, a1 = buy ? output : -input;
        result = BigInt.asIntN(256, (BigInt.asUintN(128, a0) << 128n) | BigInt.asUintN(128, a1));
      } else throw new Error(`Unexpected function ${name}`);
      return encodeFunctionResult({ abi, functionName: name, result });
    }
    throw new Error(`Unexpected RPC method ${method}`);
  };
  return f;
}
async function open(options = {}) {
  const f = fixture(options);
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, reducedMotion: 'reduce' });
  const page = await context.newPage();
  await page.clock.install();
  page.on('pageerror', e => report.consoleErrors.push(e.message));
  page.on('requestfailed', r => { if (r.url().startsWith(url)) report.resourceFailures.push(r.url()); });
  await page.route('https://**/*', async route => {
    const request = route.request();
    f.rpcUrls.push(request.url());
    if (!d.network.rpcUrls.includes(request.url().replace(/\/$/, ''))) return route.abort();
    if (options.failFirst && request.url().startsWith(d.network.rpcUrls[0])) return route.fulfill({ status: 503, body: 'Mock endpoint unavailable' });
    const body = request.postDataJSON();
    const handle = async item => {
      try { return { jsonrpc: '2.0', id: item.id, result: await f.rpc(item.method, item.params) }; }
      catch (e) { return { jsonrpc: '2.0', id: item.id, error: { code: -32000, message: e.message } }; }
    };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(Array.isArray(body) ? await Promise.all(body.map(handle)) : await handle(body)) });
  });
  if (!options.noWallet) {
    await page.exposeFunction('mockWalletRpc', (method, params) => f.rpc(method, params));
    await page.addInitScript(({ account, chainId, unknownChain }) => {
      const handlers = {};
      window.mockWallet = { accounts: [], chainId, unknownChain, requests: [], rejectConnect: false, rejectSend: false,
        emit(event, value) { for (const listener of handlers[event] ?? []) listener(value); } };
      window.ethereum = {
        on: (event, handler) => { (handlers[event] ??= []).push(handler); },
        removeListener: (event, handler) => { handlers[event] = (handlers[event] ?? []).filter(h => h !== handler); },
        async request({ method, params }) {
          const m = window.mockWallet; m.requests.push({ method, params });
          if (method === 'eth_accounts') return m.accounts;
          if (method === 'eth_requestAccounts') { if (m.rejectConnect) throw { code: 4001, message: 'User rejected' }; m.accounts = [account]; return m.accounts; }
          if (method === 'eth_chainId') return m.chainId;
          if (method === 'wallet_switchEthereumChain') { if (m.unknownChain) throw { code: 4902, message: 'Unknown chain' }; m.chainId = params[0].chainId; m.emit('chainChanged', m.chainId); return null; }
          if (method === 'wallet_addEthereumChain') { m.unknownChain = false; return null; }
          if (method === 'eth_sendTransaction' && m.rejectSend) throw { code: 4001, message: 'User rejected' };
          return window.mockWalletRpc(method, params);
        },
      };
    }, { account, chainId: options.wrongChain ? '0x1' : toHex(d.chainId), unknownChain: !!options.wrongChain });
  }
  await page.goto(url);
  await page.getByRole('heading', { name: 'A little proof of a swap.' }).waitFor();
  return { page, context, f };
}
async function connected(options = {}) {
  const session = await open(options);
  await session.page.getByRole('button', { name: 'Connect wallet', exact: false }).first().click();
  if (!options.wrongChain) await session.page.getByRole('button', { name: 'Review swap', exact: false }).waitFor({ state: 'visible' });
  return session;
}
async function waitReady(page) { await page.waitForFunction(() => document.querySelector('.live-state')?.textContent.includes('Updated at block')); await page.waitForFunction(() => !document.querySelector('#trade button[type="submit"]')?.disabled); }
async function screenshot(page, name) { await page.screenshot({ path: `${evidence}/${name}.jpg`, fullPage: true, type: 'jpeg', quality: 78 }); report.screenshots.push(`${name}.jpg`); }

try {
  let s = await open({ noWallet: true });
  await s.page.getByRole('button', { name: 'Connect wallet', exact: false }).first().click();
  await s.page.getByRole('alert').filter({ hasText: 'No browser wallet found' }).waitFor();
  check('Missing browser wallet produces an actionable error');
  await s.context.close();

  s = await open();
  await s.page.evaluate(() => window.mockWallet.rejectConnect = true);
  await s.page.getByRole('button', { name: 'Connect wallet', exact: false }).first().click();
  await s.page.getByRole('alert').filter({ hasText: 'Request declined' }).waitFor();
  check('Wallet connection rejection is recoverable');
  await s.context.close();

  s = await connected({ wrongChain: true });
  await s.page.getByRole('button', { name: 'Switch to Sepolia' }).waitFor();
  assert.equal(await s.page.getByRole('button', { name: 'Review swap' }).isDisabled(), true);
  await s.page.getByRole('button', { name: 'Switch to Sepolia' }).click();
  await waitReady(s.page);
  const requests = await s.page.evaluate(() => window.mockWallet.requests.filter(r => r.method.startsWith('wallet_')));
  assert.deepEqual(requests.map(r => r.method), ['wallet_switchEthereumChain', 'wallet_addEthereumChain', 'wallet_switchEthereumChain']);
  assert.deepEqual(requests[1].params[0], d.walletAddChain);
  check('Wrong chain blocks trading; 4902 adds exact handoff chain and switches again');
  await s.context.close();

  s = await connected({ failFirst: true });
  await waitReady(s.page);
  assert.ok(s.f.rpcUrls.some(u => u.startsWith(d.network.rpcUrls[1])));
  check('Public RPC fallback recovers after the first endpoint fails');
  await s.context.close();

  s = await connected();
  const { page, f } = s;
  await waitReady(page);
  await page.waitForFunction(() => document.querySelectorAll('.activity-row').length === 12);
  assert.equal(await page.locator('.activity-row').filter({ hasText: '#0014' }).count(), 0);
  assert.equal(await page.locator('.activity-row').filter({ hasText: '#0013' }).count(), 0);
  assert.ok(f.calls.some(c => c.functionName === 'getSlot0' && c.args[0] === poolId && c.to === d.network.uniswapV4.stateView));
  check('Live StateView reads use the derived pool ID; latest 12 use Receipt events and exclude other tokens/pools');
  await page.getByRole('button', { name: 'Load more receipts', exact: false }).click();
  await page.waitForFunction(() => document.querySelectorAll('.receipt-card').length === 14);
  assert.equal(await page.locator('.receipt-card').filter({ hasText: 'Receipt #14' }).count(), 0);
  assert.ok(await page.locator('.receipt-card img').evaluateAll(images => images.every(img => img.complete && img.naturalWidth > 0)));
  check('Wallet gallery paginates receiptsOf, filters token addresses and renders tokenURI SVG images');
  await page.getByLabel('Wallet address', { exact: true }).fill('invalid');
  await page.getByRole('button', { name: 'View receipts', exact: false }).click();
  await page.getByText('Enter a nonzero wallet address', { exact: false }).waitFor();
  assert.equal(await page.locator('#owner').evaluate(el => el === document.activeElement), true);
  await page.getByLabel('Wallet address', { exact: true }).fill(secondAccount);
  await page.getByRole('button', { name: 'View receipts', exact: false }).click();
  await page.getByText(`Viewing ${secondAccount}`, { exact: false }).waitFor();
  check('Pasted-address gallery and inline address validation work');

  await page.getByLabel('You pay up to').fill('0');
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.locator('#trade-error').filter({ hasText: 'greater than zero' }).waitFor();
  await page.getByLabel('You pay up to').fill('0.001');
  await page.getByLabel('Price tolerance').fill('10');
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.locator('#trade-error').filter({ hasText: 'between 0.1% and 5%' }).waitFor();
  await page.getByLabel('Price tolerance').fill('0.5');
  await page.getByLabel('You pay up to').fill('0.000000000000000001');
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).waitFor();
  assert.equal(await page.locator('.output-box strong').innerText(), '0.000000000001');
  check('Sub-micro-unit quoted amounts remain visible instead of rounding to zero');
  await page.getByLabel('You pay up to').fill('0.001');
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).waitFor();
  const simulatedBuy = f.calls.filter(c => c.functionName === 'swap').at(-1);
  assert.equal(simulatedBuy.to, d.execution.router);
  assert.equal(simulatedBuy.args[1].amountSpecified, -(10n ** 15n));
  assert.equal(simulatedBuy.args[1].zeroForOne, true);
  assert.equal(BigInt(simulatedBuy.value), 10n ** 15n);
  assert.equal(simulatedBuy.args[3].toLowerCase(), encodeAbiParameters([{ type: 'address' }], [account]));
  assert.deepEqual(simulatedBuy.args[2], { takeClaims: false, settleUsingBurn: false });
  assert.ok(simulatedBuy.args[1].sqrtPriceLimitX96 < BigInt(d.pool.initialPrice));
  assert.ok(f.calls.some(c => c.functionName === 'quoteExactInputSingle' && c.to === d.network.uniswapV4.quoter));
  assert.equal(f.sent.length, 0);
  check('Buy review validates input, uses configured quoter/router, ETH value, negative exact-input and wallet hookData; no signing during quote');
  await screenshot(page, 'desktop-review');

  await page.evaluate(() => window.mockWallet.rejectSend = true);
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).click();
  await page.locator('#trade-error').filter({ hasText: 'Request declined' }).waitFor();
  assert.equal(f.sent.length, 0);
  await page.evaluate(() => window.mockWallet.rejectSend = false);
  check('Rejected swap shows recovery and never fabricates confirmation');

  f.failSimulation = true;
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.locator('#trade-error').filter({ hasText: 'reverted' }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Confirm buy in wallet' }).count(), 0);
  assert.equal(f.sent.length, 0);
  f.failSimulation = false;
  check('Simulation revert blocks signing and displays the failure');

  f.partial = true;
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByText('Partial fill: the simulation', { exact: false }).waitFor();
  await page.getByText('No NFT will mint.', { exact: false }).waitFor();
  check('Partial fill shows actual simulated input and below-threshold receipt warning');
  f.partial = false;
  await page.getByRole('button', { name: 'Refresh quote & simulation' }).click();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).click();
  await page.getByRole('link', { name: 'View transaction', exact: false }).waitFor();
  await page.waitForFunction(() => document.querySelector('.live-state')?.textContent.includes('Updated at block'));
  assert.equal(f.sent.filter(tx => tx.functionName === 'swap').length, 1);
  check('Buy simulates again before mocked signing, waits for receipt and links the transaction');

  await waitReady(page);
  await page.getByRole('button', { name: 'Sell RCPT', exact: true }).click();
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Approve 100 RCPT', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('#trade button[type="submit"]')?.disabled);
  const approval = f.sent.find(tx => tx.functionName === 'approve');
  assert.ok(approval); assert.equal(approval.to.toLowerCase(), token.address);
  assert.equal(approval.args[0].toLowerCase(), d.execution.router); assert.equal(approval.args[1], 100n * 10n ** 18n);
  await waitReady(page);
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Confirm sell in wallet' }).click();
  await page.getByRole('link', { name: 'View transaction', exact: false }).waitFor();
  const sell = f.sent.filter(tx => tx.functionName === 'swap').at(-1);
  assert.equal(sell.args[1].zeroForOne, false); assert.equal(BigInt(sell.value ?? '0x0'), 0n);
  assert.ok(sell.args[1].sqrtPriceLimitX96 > BigInt(d.pool.initialPrice));
  assert.ok(!f.sent.some(tx => tx.to.toLowerCase() === d.network.uniswapV4.permit2));
  check('Sell requires separate exact-amount approval to PoolSwapTest, then simulation and zero-value swap');

  await waitReady(page);
  await page.getByRole('button', { name: 'Buy RCPT', exact: true }).click();
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).waitFor();
  await page.clock.fastForward(61000);
  await page.waitForFunction(() => document.querySelector('.review button')?.disabled);
  assert.equal(await page.getByRole('button', { name: 'Confirm buy in wallet' }).isDisabled(), true);
  check('Expired review cannot be signed');
  await page.getByRole('button', { name: 'Refresh quote & simulation' }).click();
  await page.evaluate(second => { window.mockWallet.accounts = [second]; window.mockWallet.emit('accountsChanged', [second]); }, secondAccount);
  await page.waitForFunction(() => !document.querySelector('.review'));
  check('Account change discards the previous trade review');

  await page.clock.resume();
  await waitReady(page);
  await page.getByRole('button', { name: 'Buy RCPT', exact: true }).click();
  await page.getByRole('button', { name: 'Review swap' }).click();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).waitFor();
  const a11y = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
  writeFileSync(`${evidence}/accessibility.json`, JSON.stringify({ violations: a11y.violations, incomplete: a11y.incomplete.map(i => ({ id: i.id, impact: i.impact, description: i.description, nodes: i.nodes.map(n => ({ target: n.target, html: n.html, summary: n.failureSummary })) })), passes: a11y.passes.map(p => p.id) }, null, 2) + '\n');
  assert.equal(a11y.violations.length, 0, JSON.stringify(a11y.violations.map(v => ({ id: v.id, nodes: v.nodes.map(n => n.target) }))));
  check('Automated accessibility: no WCAG A/AA violations in populated trade/receipt state');
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    const overflow = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth, elements: [...document.querySelectorAll('body *')].filter(el => el.getBoundingClientRect().right > innerWidth + 1).map(el => ({ tag: el.tagName, className: el.className, right: el.getBoundingClientRect().right })) }));
    assert.equal(overflow.scroll <= width, true, `Overflow at ${width}: ${JSON.stringify(overflow)}`);
    if (width === 390 || width === 320) await screenshot(page, `mobile-${width}`);
    check(`No horizontal overflow at ${width} CSS pixels`);
  }
  await page.setViewportSize({ width: 768, height: 900 });
  await page.evaluate(() => document.documentElement.style.fontSize = '200%');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.evaluate(() => document.documentElement.style.fontSize = '');
  check('200% root text enlargement reflows at 768px (not browser-native zoom)');
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.evaluate(() => { window.scrollTo(0, 0); document.activeElement?.blur(); });
  await page.keyboard.press('Control+Home');
  await page.evaluate(() => { const skip = document.querySelector('.skip'); skip.focus(); });
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement.classList.contains('brand')), true);
  await screenshot(page, 'keyboard-focus');
  check('Keyboard skip link, native form controls and visible focus captured');

  const beforeKeyboardSwap = f.sent.length;
  await page.getByLabel('You pay up to').focus();
  await page.keyboard.press('Control+A'); await page.keyboard.type('0.002');
  await page.keyboard.press('Enter');
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).waitFor();
  await page.getByRole('button', { name: 'Confirm buy in wallet' }).focus();
  await page.keyboard.press('Space');
  await page.getByRole('link', { name: 'View transaction', exact: false }).waitFor();
  assert.equal(f.sent.length, beforeKeyboardSwap + 1);
  check('Keyboard Enter reviews the swap and Space activates mocked confirmation');
  await waitReady(page);

  report.computed = await page.evaluate(() => {
    const s = getComputedStyle(document.body), button = getComputedStyle(document.querySelector('.primary')), muted = getComputedStyle(document.querySelector('.field-hint'));
    return { body: { color: s.color, background: s.backgroundColor, font: s.fontFamily }, primary: { color: button.color, background: button.backgroundColor }, muted: { color: muted.color }, focus: { outline: getComputedStyle(document.activeElement).outline } };
  });
  await s.context.close();

  s = await connected({ noCode: true });
  await s.page.getByRole('alert').filter({ hasText: 'No deployed code' }).waitFor();
  assert.equal(await s.page.getByRole('button', { name: 'Review swap' }).isDisabled(), true);
  check('Missing deployed code keeps transaction controls disabled');
  await s.context.close();

  const context = await browser.newContext(); const badPage = await context.newPage();
  await badPage.route('**/abi/RCPT.json', route => route.fulfill({ contentType: 'application/json', body: '[]' }));
  await badPage.goto(url);
  await badPage.getByRole('heading', { name: 'Deployment could not be verified' }).waitFor();
  await badPage.getByRole('alert').filter({ hasText: 'ABI failed attestation' }).waitFor();
  check('Tampered ABI fails closed before the trading UI opens');
  await context.close();
  assert.deepEqual(report.consoleErrors, []);
  assert.deepEqual(report.resourceFailures, []);
  check('Production gateway-subpath export loads with no JavaScript errors or missing local resources');
  report.result = 'PASS';
} catch (error) {
  report.result = 'FAIL'; report.failure = error.stack;
  console.error(error);
  for (const context of browser.contexts()) for (const page of context.pages()) { await page.screenshot({ path: `${evidence}/failure.jpg`, fullPage: true, type: 'jpeg' }).catch(() => {}); console.log((await page.locator('body').innerText()).slice(-8000)); }
  process.exitCode = 1;
} finally {
  writeFileSync(`${evidence}/interactions.json`, JSON.stringify(report, null, 2) + '\n');
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
