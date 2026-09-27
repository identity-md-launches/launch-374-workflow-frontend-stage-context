import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { createWalletClient, custom, isAddress, type Address, type Hex } from 'viem';
import { loadConfig, makeClient, type Config } from './config';
import { amountValue, deltaAmounts, display, ensureWallet, errorText, latestPage, ownerPage, readState, short, swapArgs, switchChain, verify, type Receipt, type State } from './chain';
import './styles.css';

function Mark({ small = false }: { small?: boolean }) {
  return <svg className={small ? 'mark small' : 'mark'} viewBox="0 0 40 40" fill="none" aria-hidden="true"><path d="M11 5h18v30l-4-3-5 3-5-3-4 3V5Z" stroke="currentColor" strokeWidth="2"/><path d="M16 13h8m-8 6h8m-8 6h4" stroke="currentColor" strokeWidth="2"/></svg>;
}
function OutLink({ href, children }: { href: string; children: ReactNode }) { return <a href={href} target="_blank" rel="noreferrer">{children}<span aria-hidden="true"> ↗</span></a>; }
function App({ c }: { c: Config }) {
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [walletBusy, setWalletBusy] = useState(false);
  const [walletError, setWalletError] = useState('');
  const [state, setState] = useState<State>();
  const [verified, setVerified] = useState(false);
  const [readError, setReadError] = useState('');
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);
  const [latest, setLatest] = useState<Receipt[]>([]);
  const [latestCursor, setLatestCursor] = useState(0n);
  const [latestError, setLatestError] = useState('');
  const [latestBusy, setLatestBusy] = useState(false);
  const [ownerInput, setOwnerInput] = useState('');
  const [owner, setOwner] = useState<Address>();
  const [gallery, setGallery] = useState<Receipt[]>([]);
  const [galleryNext, setGalleryNext] = useState(0n);
  const [galleryTotal, setGalleryTotal] = useState(0n);
  const [galleryBusy, setGalleryBusy] = useState(false);
  const [galleryError, setGalleryError] = useState('');
  const galleryEpoch = useRef(0);
  const latestEpoch = useRef(0);
  const onChain = chainId === c.chain.id;
  const client = useMemo(() => makeClient(c, account && onChain ? window.ethereum : undefined), [c, account, onChain]);
  const explorer = c.deployment.network.explorer;

  useEffect(() => {
    const provider = window.ethereum;
    if (!provider) return;
    const accountsChanged = (accounts: Address[]) => { setAccount(accounts[0]); };
    const chainChanged = (chain: string) => { setChainId(Number(chain)); setVerified(false); };
    const disconnect = () => { setAccount(undefined); setChainId(undefined); };
    provider.on?.('accountsChanged', accountsChanged);
    provider.on?.('chainChanged', chainChanged);
    provider.on?.('disconnect', disconnect);
    Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]).then(([a, id]) => { setAccount(a[0]); setChainId(Number(id)); }).catch(() => {});
    return () => { provider.removeListener?.('accountsChanged', accountsChanged); provider.removeListener?.('chainChanged', chainChanged); provider.removeListener?.('disconnect', disconnect); };
  }, []);
  async function connect() {
    setWalletBusy(true); setWalletError('');
    try {
      if (!window.ethereum) throw new Error('No browser wallet found. Open this page in a wallet browser or install a browser wallet, then reload.');
      const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
      if (!accounts[0]) throw new Error('No account selected. Select an account in your wallet and try again.');
      setAccount(accounts[0]);
      setChainId(Number(await window.ethereum.request({ method: 'eth_chainId' })));
    } catch (e) { setWalletError(errorText(e)); } finally { setWalletBusy(false); }
  }
  async function changeChain() {
    if (!window.ethereum) return;
    setWalletBusy(true); setWalletError('');
    try { await switchChain(window.ethereum, c); setChainId(Number(await window.ethereum.request({ method: 'eth_chainId' }))); setRefresh(v => v + 1); }
    catch (e) { setWalletError(errorText(e)); } finally { setWalletBusy(false); }
  }
  useEffect(() => {
    let active = true;
    setVerified(false); setLoading(true); setReadError(''); setState(undefined);
    async function read() {
      try {
        await verify(c, client);
        const next = await readState(c, client, account);
        if (!active) return;
        setState(next); setVerified(true); setReadError('');
      } catch (e) { if (active) { setReadError(errorText(e)); setVerified(false); } }
      finally { if (active) setLoading(false); }
    }
    void read();
    const timer = setInterval(() => { if (document.visibilityState === 'visible') void read(); }, 30000);
    return () => { active = false; clearInterval(timer); };
  }, [c, client, account, refresh]);

  const readLatest = useCallback(async (start: bigint, reset: boolean) => {
    const epoch = ++latestEpoch.current;
    setLatestBusy(true); setLatestError('');
    try {
      let cursor = start;
      let records: Receipt[] = reset ? [] : latest;
      // Bounded scans with an explicit continuation for busy multi-pool hooks.
      for (let pages = 0; pages < 5 && cursor > 0n && records.length < 12; pages++) {
        const page = await latestPage(c, client, cursor);
        records = [...records, ...page.records]; cursor = page.cursor;
      }
      if (epoch === latestEpoch.current) { setLatest(records.slice(0, 12)); setLatestCursor(cursor); }
    } catch (e) { if (epoch === latestEpoch.current) setLatestError(errorText(e)); }
    finally { if (epoch === latestEpoch.current) setLatestBusy(false); }
  }, [c, client, latest]);
  useEffect(() => { if (state) void readLatest(state.total, true); }, [state?.total, client, refresh]); // refresh event data after confirmed swaps

  const readGallery = useCallback(async (address: Address, offset: bigint) => {
    const epoch = ++galleryEpoch.current;
    setGalleryBusy(true); setGalleryError('');
    if (!offset) { setGallery([]); setGalleryNext(0n); setGalleryTotal(0n); }
    try {
      const page = await ownerPage(c, client, address, offset);
      if (epoch !== galleryEpoch.current) return;
      setGallery(previous => offset ? [...previous, ...page.records] : page.records); setGalleryNext(page.next); setGalleryTotal(page.total);
    } catch (e) { if (epoch === galleryEpoch.current) setGalleryError(errorText(e)); }
    finally { if (epoch === galleryEpoch.current) setGalleryBusy(false); }
  }, [c, client]);
  useEffect(() => { if (account) { setOwnerInput(account); setOwner(account); } }, [account]);
  useEffect(() => { if (owner) void readGallery(owner, 0n); return () => { galleryEpoch.current++; }; }, [owner, readGallery, refresh, state?.total]);
  function searchOwner(e: FormEvent) {
    e.preventDefault();
    if (!isAddress(ownerInput) || /^0x0{40}$/i.test(ownerInput)) { setGalleryError('Enter a nonzero wallet address starting with 0x (42 characters).'); document.getElementById('owner')?.focus(); return; }
    if (owner === ownerInput) void readGallery(ownerInput, 0n); else setOwner(ownerInput);
  }

  return <>
    <a className="skip" href="#main">Skip to content</a>
    <div className="shell">
      <header className="header">
        <a className="brand" href="#main"><span className="brand-icon"><Mark small /></span>receipts</a>
        <nav aria-label="Main navigation"><a href="#trade">Trade</a><a href="#collection">Collection</a><a href="#activity">Activity</a></nav>
        <div className="wallet"><span className="network-badge"><span aria-hidden="true">◉</span> {c.chain.name} testnet</span>
          {account ? <details className="wallet-details"><summary>{short(account)}</summary><div><span className="address">{account}</span><button onClick={() => { setAccount(undefined); setChainId(undefined); }}>Disconnect locally</button></div></details> : <button onClick={connect} disabled={walletBusy}>{walletBusy ? 'Connecting…' : 'Connect wallet'} <span aria-hidden="true">↗</span></button>}
        </div>
      </header>
      <main id="main">
        <section className="hero">
          <div className="hero-copy"><p className="eyebrow"><span className="mini-line"/> On-chain moments, kept forever</p><h1>A little proof<br/>of a <span className="serif">swap.</span></h1><p className="intro">Trade RCPT. Collect the moment.<br/>Every qualifying buy leaves a receipt on Sepolia.</p><div className="hero-tags"><span>Fully on-chain</span><span>Soulbound</span><span>No hook fee</span></div></div>
          <div className="receipt-scene" role="img" aria-label="Illustration of a swap receipt, not a minted NFT">
            <div className="orbit orbit-one"/><div className="orbit orbit-two"/>
            <div className="sample-receipt"><div className="sample-top"><Mark/><span>Swap receipts<br/><small>Sepolia edition</small></span><span aria-hidden="true">↗</span></div><div className="sample-rule"/><p className="sample-caption">A swap worth keeping.</p><div className="sample-amount">0.001 <span>ETH</span></div><p className="sample-sub">Minimum settled buy for a receipt</p><div className="sample-rule"/><div className="sample-bottom"><div><span className="eyebrow">Made to stay</span><strong>Yours, forever.</strong></div><span className="receipt-stamp">On<br/>chain</span></div><div className="barcode" aria-hidden="true"/><span className="sample-label">Illustration · actual artwork is stored on-chain</span></div>
          </div>
        </section>
        <div className="stats" role="group" aria-label="Live pool statistics">
          <div><span className="eyebrow">Pool price</span><strong>{state ? `${state.price.toLocaleString('en-US', { maximumFractionDigits: 2 })} RCPT` : '—'}</strong><small>per 1 ETH · StateView spot price</small></div>
          <div><span className="eyebrow">Receipts minted</span><strong>{state ? state.total.toLocaleString() : '—'}<span className="stat-unit"> all pools</span></strong><small>This hook’s lifetime collection</small></div>
          <div><span className="eyebrow">Qualifying buy</span><strong>{state ? display(state.threshold) : '0.001'}<span className="stat-unit"> ETH</span></strong><small>Settled amount, excluding gas</small></div>
          <div className="live-state"><span className={`status-dot ${verified ? 'connected' : ''}`}/><span>{loading ? 'Connecting to Sepolia…' : verified ? `Updated at block ${state?.block.toLocaleString()}` : 'Live data unavailable'}<small>Refreshes every 30 seconds</small></span><button className="icon-button" aria-label="Refresh live data" onClick={() => setRefresh(v => v + 1)} disabled={loading}>↻</button></div>
        </div>
        {(readError || walletError) && <div className="error banner" role="alert">{walletError || readError} {readError && 'Use Refresh live data to retry.'}</div>}
        {account && !onChain && <div className="network-warning"><span>Your wallet is on a different network. Switch to {c.chain.name} to trade.</span><button onClick={changeChain} disabled={walletBusy}>{walletBusy ? 'Switching…' : `Switch to ${c.chain.name}`}</button></div>}
        <section id="trade" className="trade-section">
          <div className="trade-story"><p className="eyebrow">01 / Make a swap</p><h2>Trade a token.<br/>Keep a <span className="serif">memento.</span></h2><p>Buy at least 0.001 ETH of RCPT to receive a unique, non-transferable NFT. Its artwork and details live entirely on-chain.</p><ol className="steps"><li><span>01</span><div><strong>Connect on Sepolia</strong><p>Use a browser wallet with test ETH for the swap and gas.</p></div></li><li><span>02</span><div><strong>Review, then swap</strong><p>See a quote and simulate the swap before signing.</p></div></li><li><span>03</span><div><strong>Find your receipt below</strong><p>A qualifying settled buy mints automatically. Sells do not mint.</p></div></li></ol><a href={c.deployment.network.faucets[0]} target="_blank" rel="noreferrer" className="text-link">Get Sepolia test ETH <span aria-hidden="true">↗</span></a></div>
          <Trade c={c} client={client} account={account} ready={verified && onChain} state={state} connect={connect} walletBusy={walletBusy} onDone={() => setRefresh(v => v + 1)} />
        </section>
        <section id="collection" className="collection-section">
          <div className="section-heading"><div><p className="eyebrow">02 / Your collection</p><h2>Small swaps.<br className="mobile-only"/> Lasting <span className="serif">receipts.</span></h2></div><span className="quiet-badge">Non-transferable by design</span></div>
          <div className="collection-bar"><form className="owner-form" onSubmit={searchOwner}><label htmlFor="owner">Wallet address</label><div className="input-row"><input id="owner" name="owner" placeholder="0x… or connect your wallet" value={ownerInput} onChange={e => { setOwnerInput(e.target.value); setGalleryError(''); }} spellCheck={false} autoComplete="off" aria-invalid={!!galleryError} aria-describedby="owner-help gallery-error"/><button disabled={galleryBusy} type="submit">{galleryBusy ? 'Loading…' : 'View receipts'} <span aria-hidden="true">→</span></button></div><span className="field-hint" id="owner-help">Browse any address. Only launch-token receipts are shown.</span></form>{account && <button className="plain-button" onClick={() => { setOwnerInput(account); setOwner(account); }}>Use connected wallet</button>}</div>
          <p className="error" id="gallery-error" role="alert">{galleryError}</p>
          {gallery.length > 0 ? <div className="receipt-grid">{gallery.map(r => <ReceiptCard key={r.id.toString()} r={r} c={c} decimals={state?.decimals ?? 18}/>)}</div> : <div className="empty-state"><span className="empty-icon"><Mark/></span><h3>{galleryBusy ? 'Finding your on-chain moments…' : owner ? 'No RCPT receipts on this page yet' : 'Your collection starts with a swap'}</h3><p>{owner ? 'A settled buy of at least 0.001 ETH creates a receipt. Other tokens are filtered out.' : 'Connect your wallet or paste an address above to explore its receipts.'}</p>{!owner && <a href="#trade">Make your first swap <span aria-hidden="true">↑</span></a>}</div>}
          {owner && galleryNext < galleryTotal && <button className="load-more" disabled={galleryBusy} onClick={() => void readGallery(owner, galleryNext)}>Load more receipts ({galleryNext.toString()} of {galleryTotal.toString()} checked)</button>}
          {owner && <p className="field-hint address">Viewing {owner} · {gallery.length} RCPT receipts loaded</p>}
          <aside className="identity-note"><span aria-hidden="true">ⓘ</span><p><strong>A record of a buy, not proof of identity.</strong> Anyone can credit a receipt to any address through hookData. A receipt does not prove its owner made the trade. Receipts cannot be transferred, approved or burned.</p></aside>
        </section>
        <section id="activity" className="activity-section"><div className="section-heading"><div><p className="eyebrow">03 / Fresh off the chain</p><h2>The latest <span className="serif">12.</span></h2></div><button onClick={() => state && void readLatest(state.total, true)} disabled={!state || latestBusy}>{latestBusy ? 'Loading mints…' : 'Refresh mints'} <span aria-hidden="true">↻</span></button></div><p className="section-description">Qualifying buys from the RCPT launch pool, newest first.</p><p role="alert" className="error">{latestError}</p>
          {latest.length ? <div className="activity-list"><div className="activity-labels"><span>Receipt / time</span><span>Credited wallet</span><span>ETH paid</span><span>RCPT received</span><span>Transaction</span></div>{latest.map(r => <div className="activity-row" key={r.id.toString()}><div><strong>#{r.id.toString().padStart(4, '0')}</strong><small>{new Date(Number(r.timestamp) * 1000).toLocaleString()}</small></div><OutLink href={`${explorer}/address/${r.owner}`}>{short(r.owner!)}</OutLink><span><span className="mobile-label">Paid </span>{display(r.ethPaid)} ETH</span><span><span className="mobile-label">Received </span>{display(r.tokensReceived, state?.decimals ?? 18, 2)} RCPT</span><OutLink href={`${explorer}/tx/${r.transactionHash}`}>View swap</OutLink></div>)}</div> : <div className="activity-empty">{latestBusy ? 'Reading mint records and Receipt events…' : state ? 'No launch-pool mints found yet. The next qualifying buy could be the first.' : 'Live mint activity will appear when Sepolia data is available.'}</div>}
          {latestCursor > 0n && latest.length < 12 && <button className="load-more" disabled={latestBusy} onClick={() => void readLatest(latestCursor, false)}>Search older mint records</button>}
        </section>
        <details className="deployment-details"><summary>Deployment & pool details <span>Source and addresses ↗</span></summary><div className="deployment-grid">{c.deployment.contracts.map(contract => <div key={contract.name}><strong>{contract.name}</strong><OutLink href={`${explorer}/address/${contract.address}`}><span className="address">{contract.address}</span></OutLink><a href={`./${contract.abiPath}`}>View attested ABI JSON</a></div>)}{Object.entries({ PoolSwapTest: c.deployment.execution.router, StateView: c.deployment.network.uniswapV4.stateView, Quoter: c.deployment.network.uniswapV4.quoter, PoolManager: c.deployment.network.uniswapV4.poolManager }).map(([name, address]) => <div key={name}><strong>{name}</strong><OutLink href={`${explorer}/address/${address}`}><span className="address">{address}</span></OutLink></div>)}<div><strong>Pool ID</strong><span className="address">{c.poolId}</span><span>{c.poolKey.fee / 10000}% pool fee · tick spacing {c.poolKey.tickSpacing}</span></div><div><strong>Deployment source</strong><span className="address">{c.deployment.sourceCommit}</span><a href="./imd-deployment.json">View runtime deployment manifest</a></div></div></details>
      </main>
      <footer><a className="brand" href="#main"><Mark small/>receipts</a><p>A moment on-chain. A receipt for keeps.</p><span>Sepolia only · Test tokens have no monetary value.</span></footer>
    </div>
  </>;
}

function ReceiptCard({ r, c, decimals }: { r: Receipt; c: Config; decimals: number }) {
  return <article className="receipt-card"><img src={r.image} alt={`On-chain artwork for Swap Receipt #${r.id}`} loading="lazy" width="420" height="420"/><div><h3>Receipt #{r.id.toString()}</h3><span className="quiet-badge">Soulbound</span><p>{display(r.ethPaid)} ETH → {display(r.tokensReceived, decimals, 2)} RCPT</p><OutLink href={`${c.deployment.network.explorer}/token/${c.hook.address}?a=${r.id}`}>View receipt</OutLink></div></article>;
}

type Review = { args: ReturnType<typeof swapArgs>; referenceOutput: bigint; at: number; input?: bigint; output?: bigint; fingerprint: string };
function Trade({ c, client, account, ready, state, connect, walletBusy, onDone }: { c: Config; client: ReturnType<typeof makeClient>; account?: Address; ready: boolean; state?: State; connect: () => void; walletBusy: boolean; onDone: () => void }) {
  const [buy, setBuy] = useState(true);
  const [amount, setAmount] = useState('0.001');
  const [tolerance, setTolerance] = useState('0.5');
  const [review, setReview] = useState<Review>();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [hash, setHash] = useState<Hex>();
  const [now, setNow] = useState(Date.now());
  const epoch = useRef(0);
  const fingerprint = `${account}:${ready}:${buy}:${amount}:${tolerance}`;
  const current = useRef(fingerprint); current.current = fingerprint;
  const lock = useRef(false);
  useEffect(() => { epoch.current++; setReview(undefined); }, [fingerprint]);
  useEffect(() => { setError(''); setMessage(''); }, [account, buy, amount, tolerance]);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const expired = !!review && now - review.at > 60000;
  let amountWei = 0n; try { amountWei = amountValue(amount, buy ? 18 : state?.decimals ?? 18); } catch { /* validate on submit */ }
  const needsApproval = !buy && !!state && state.allowance < amountWei;
  const available = buy ? state?.nativeBalance : state?.tokenBalance;
  const unit = buy ? 'ETH' : 'RCPT', outputUnit = buy ? 'RCPT' : 'ETH';
  async function run(task: () => Promise<void>) {
    if (lock.current) return;
    lock.current = true; setBusy(true); setError(''); setHash(undefined);
    try { await task(); } catch (e) { setError(errorText(e)); setMessage(''); setReview(undefined); }
    finally { setBusy(false); lock.current = false; }
  }
  async function getReview(e: FormEvent) {
    e.preventDefault();
    await run(async () => {
      if (!account || !window.ethereum || !ready || !state) throw new Error('Connect on the configured network and wait for verified live data.');
      let input: bigint;
      try { input = amountValue(amount, buy ? 18 : state.decimals); } catch (e) { document.getElementById('amount')?.focus(); throw e; }
      if (input > (available ?? 0n)) throw new Error(`Insufficient ${unit}. Reduce the amount or fund your wallet.`);
      const bps = Number(tolerance) * 100;
      if (!Number.isInteger(bps) || bps < 10 || bps > 500) { document.getElementById('tolerance')?.focus(); throw new Error('Choose a price tolerance between 0.1% and 5%.'); }
      const ticket = epoch.current;
      await ensureWallet(window.ethereum, c, account);
      await verify(c, client);
      const fresh = await readState(c, client, account);
      const args = swapArgs(c, account, buy, input, fresh.sqrtPrice, bps);
      setMessage('Reading a quote from the Uniswap quoter…');
      const quote = await client.simulateContract({ address: c.deployment.network.uniswapV4.quoter, abi: c.abis.quoter, functionName: 'quoteExactInputSingle', args: [{ poolKey: c.poolKey, zeroForOne: buy, exactAmount: input, hookData: args[3] }], account });
      const referenceOutput = (quote.result as [bigint, bigint])[0];
      if (!referenceOutput) throw new Error('No output quoted. Try a smaller amount and refresh live data.');
      let simulated: { input: bigint; output: bigint } | undefined;
      if (buy || fresh.allowance >= input) {
        setMessage('Simulating the price-limited swap…');
        const sim = await client.simulateContract({ address: c.deployment.execution.router, abi: c.abis.router, functionName: 'swap', args, account, value: buy ? input : 0n });
        simulated = deltaAmounts(sim.result as bigint, buy);
      }
      if (ticket !== epoch.current || current.current !== fingerprint) return;
      setReview({ args, referenceOutput, ...simulated, at: Date.now(), fingerprint }); setNow(Date.now());
      setMessage(simulated ? 'Simulation passed. Review the amounts before confirming in your wallet.' : 'Quote ready. Approve this RCPT amount, then review the swap again.');
    });
  }
  async function approve() {
    await run(async () => {
      if (!account || !window.ethereum || !ready || !review || expired || review.fingerprint !== current.current) throw new Error('Review the swap again before approving.');
      await ensureWallet(window.ethereum, c, account); await verify(c, client);
      setMessage(`Simulating approval of ${amount} RCPT to PoolSwapTest…`);
      const simulation = await client.simulateContract({ ...c.token, functionName: 'approve', args: [c.deployment.execution.router, amountWei], account });
      await ensureWallet(window.ethereum, c, account);
      if (review.fingerprint !== current.current || Date.now() - review.at > 60000) throw new Error('Trade changed or review expired. Review it again.');
      setMessage('Confirm the exact-amount approval in your wallet…');
      const wallet = createWalletClient({ account, chain: c.chain, transport: custom(window.ethereum) });
      const tx = await wallet.writeContract(simulation.request); setHash(tx); setMessage('Approval submitted. Waiting for confirmation…');
      const receipt = await client.waitForTransactionReceipt({ hash: tx, timeout: 120000, onReplaced: replacement => setHash(replacement.transaction.hash) });
      if (receipt.status !== 'success') throw new Error('Approval reverted. Check the transaction and try again.');
      setReview(undefined); setMessage('Approval confirmed. Review the swap again to simulate it.'); onDone();
    });
  }
  async function swap() {
    await run(async () => {
      if (!account || !window.ethereum || !ready || !review?.output || expired || review.fingerprint !== current.current) throw new Error('The review expired or the wallet changed. Review the swap again.');
      await ensureWallet(window.ethereum, c, account); await verify(c, client);
      setMessage('Rechecking the swap before requesting your signature…');
      const value = buy ? -review.args[1].amountSpecified : 0n;
      const sim = await client.simulateContract({ address: c.deployment.execution.router, abi: c.abis.router, functionName: 'swap', args: review.args, account, value });
      const actual = deltaAmounts(sim.result as bigint, buy);
      if (actual.input !== review.input || actual.output !== review.output) throw new Error('The pool changed since your review. Review the updated amounts again.');
      await ensureWallet(window.ethereum, c, account);
      if (review.fingerprint !== current.current || Date.now() - review.at > 60000) throw new Error('Review expired. Review the swap again.');
      setMessage('Confirm the swap in your wallet…');
      const wallet = createWalletClient({ account, chain: c.chain, transport: custom(window.ethereum) });
      const tx = await wallet.writeContract(sim.request); setHash(tx); setMessage('Swap submitted. Waiting for confirmation…');
      const result = await client.waitForTransactionReceipt({ hash: tx, timeout: 120000, onReplaced: replacement => setHash(replacement.transaction.hash) });
      if (result.status !== 'success') throw new Error('Swap reverted. Check the transaction details and review a new quote.');
      setReview(undefined); setMessage('Swap confirmed. Refreshing balances and receipts…'); onDone();
    });
  }
  return <div className="trade-card"><div className="trade-card-heading"><h3>Swap RCPT</h3><span className="quiet-badge">Uniswap v4</span></div>
    <div className="trade-toggle" role="group" aria-label="Trade direction"><button aria-pressed={buy} disabled={busy} onClick={() => { setBuy(true); setAmount('0.001'); }}>Buy RCPT</button><button aria-pressed={!buy} disabled={busy} onClick={() => { setBuy(false); setAmount('100'); }}>Sell RCPT</button></div>
    <form onSubmit={getReview}><div className="amount-box"><div className="amount-top"><label htmlFor="amount">You pay up to</label><span>Balance: {account && available !== undefined ? display(available, buy ? 18 : state?.decimals) : '—'}</span></div><div className="amount-entry"><input id="amount" name="amount" inputMode="decimal" value={amount} onChange={e => setAmount(e.target.value)} disabled={busy} aria-describedby="trade-error amount-help" aria-invalid={!!error} autoComplete="off"/><span className="currency"><span className={buy ? 'eth-coin' : 'rcpt-coin'} aria-hidden="true">{buy ? 'Ξ' : 'R'}</span>{unit}</span></div></div><div className="swap-arrow" aria-hidden="true">↓</div>
      <div className="output-box"><span>Estimated receive</span><div><strong>{review ? display(review.output ?? review.referenceOutput, buy ? state?.decimals : 18, 6) : '—'}</strong><span>{outputUnit}</span></div><small>{review?.output ? 'Price-limited router simulation' : 'Review for a live quote'}</small></div>
      <div className="tolerance-row"><label htmlFor="tolerance">Price tolerance</label><div><input id="tolerance" name="tolerance" inputMode="decimal" value={tolerance} onChange={e => setTolerance(e.target.value)} disabled={busy} aria-describedby="price-help"/><span>%</span></div></div>
      <p className="field-hint" id="price-help">Limits the pool’s price movement from your quote. Partial fills are possible; unused input stays with or returns to your wallet. This router has no minimum-output or deadline parameter.</p>
      <div className="receipt-eligibility" id="amount-help"><Mark small/><span>{buy ? 'A settled buy of at least 0.001 ETH mints one receipt to your connected wallet.' : 'Selling RCPT does not mint a receipt. Existing receipts stay in your wallet.'}</span></div>
      {!account ? <button type="button" className="primary" onClick={connect} disabled={walletBusy}>{walletBusy ? 'Connecting…' : 'Connect wallet to trade'} <span aria-hidden="true">↗</span></button> : <button type="submit" className={!review || expired ? 'primary' : 'secondary full'} disabled={busy || !ready || !state?.sqrtPrice}>{busy ? 'Working…' : review ? 'Refresh quote & simulation' : 'Review swap'} <span aria-hidden="true">→</span></button>}
    </form>
    {account && !ready && <p className="field-hint">Trading unlocks after your wallet network and live contract checks pass.</p>}
    {review && <div className="review"><h4>Review {buy ? 'buy' : 'sell'}</h4><dl><div><dt>Quoted output, before price limit</dt><dd>{display(review.referenceOutput, buy ? state?.decimals : 18)} {outputUnit}</dd></div>{review.input && <div><dt>Simulated input used</dt><dd>{display(review.input, buy ? 18 : state?.decimals)} {unit}</dd></div>}<div><dt>Pool fee</dt><dd>{c.poolKey.fee / 10000}%</dd></div><div><dt>Network gas</dt><dd>Additional · shown in wallet</dd></div><div><dt>Review valid for</dt><dd>{expired ? 'Expired — refresh quote' : `${Math.max(0, Math.ceil((60000 - (now - review.at)) / 1000))} seconds`}</dd></div></dl>{review.input && review.input < amountWei && <p className="notice">Partial fill: the simulation uses less than your entered amount.</p>}{buy && review.input && state && review.input < state.threshold && <p className="notice">This simulated buy is below the receipt threshold. No NFT will mint.</p>}
      <p className="field-hint">{buy ? 'No token approval needed for ETH.' : `Approve only ${amount} RCPT to PoolSwapTest. No Permit2 approval is used by this router.`}</p>
      {needsApproval ? <button className="primary" disabled={busy || expired || !ready} onClick={approve}>Approve {amount} RCPT</button> : <button className="primary" disabled={busy || expired || !ready || !review.output} onClick={swap}>Confirm {buy ? 'buy' : 'sell'} in wallet <span aria-hidden="true">↗</span></button>}
    </div>}
    <p className="transaction-status" role="status">{message}</p><p className="error" id="trade-error" role="alert">{error}</p>{hash && <div className="transaction-link"><OutLink href={`${c.deployment.network.explorer}/tx/${hash}`}>View transaction {short(hash)}</OutLink></div>}
    <p className="trade-footnote">Sepolia test tokens only. Powered by PoolSwapTest.</p>
  </div>;
}
function Bootstrap() {
  const [config, setConfig] = useState<Config>(); const [error, setError] = useState('');
  useEffect(() => { loadConfig().then(setConfig).catch(e => setError(errorText(e))); }, []);
  if (!config) return <main className="boot"><Mark/><h1>{error ? 'Deployment could not be verified' : 'Opening Receipts…'}</h1><p role={error ? 'alert' : 'status'}>{error || 'Loading deployment configuration and attested ABIs.'}</p>{error && <button onClick={() => window.location.reload()}>Retry loading</button>}</main>;
  return <App c={config}/>;
}
createRoot(document.getElementById('root')!).render(<Bootstrap/>);
