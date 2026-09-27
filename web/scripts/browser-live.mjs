import { createServer } from 'node:http';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, extname } from 'node:path';
import { chromium } from 'playwright';
const root = resolve('../dist'), evidence = resolve('../docs/evidence');
const server = createServer((req, res) => {
  try {
    const path = new URL(req.url, 'http://localhost').pathname;
    if (!path.startsWith('/preview/')) throw Error('Wrong base');
    const file = resolve(root, path.slice(9) || 'index.html');
    if (!file.startsWith(root + '/')) throw Error('Bad path');
    res.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' })[extname(file)] ?? 'text/plain' }); res.end(readFileSync(file));
  } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
const report = { checkedAt: new Date().toISOString(), browser: await browser.version(), walletConnected: false, mocked: false, consoleErrors: [], failedRequests: [], screenshots: [] };
page.on('pageerror', e => report.consoleErrors.push(e.message));
page.on('requestfailed', r => report.failedRequests.push({ url: r.url(), error: r.failure()?.errorText }));
try {
  await page.goto(`http://127.0.0.1:${server.address().port}/preview/`);
  await page.waitForFunction(() => /Updated at block|Live data unavailable/.test(document.querySelector('.live-state')?.textContent ?? ''), undefined, { timeout: 45000 });
  report.status = await page.locator('.live-state').innerText();
  report.stats = await page.locator('.stats').innerText();
  await page.screenshot({ path: `${evidence}/live-desktop.jpg`, type: 'jpeg', quality: 85 }); report.screenshots.push('live-desktop.jpg');
  await page.screenshot({ path: `${evidence}/live-full-page.jpg`, type: 'jpeg', quality: 78, fullPage: true }); report.screenshots.push('live-full-page.jpg');
  report.colors = await page.evaluate(() => {
    function rgb(s) { return s.match(/[\d.]+/g).slice(0, 3).map(Number); }
    function luminance(c) { return rgb(c).map(v => { const x = v / 255; return x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4; }).reduce((s, v, i) => s + v * [.2126, .7152, .0722][i], 0); }
    function pair(selector, bgSelector) { const fg = getComputedStyle(document.querySelector(selector)).color, bg = getComputedStyle(document.querySelector(bgSelector)).backgroundColor; const a = luminance(fg), b = luminance(bg); return { selector, backgroundSelector: bgSelector, foreground: fg, background: bg, contrast: +((Math.max(a, b) + .05) / (Math.min(a, b) + .05)).toFixed(2) }; }
    return [pair('h1', 'body'), pair('.intro', 'body'), pair('.field-hint', '.trade-card'), pair('.primary', '.primary'), pair('.sample-label', '.sample-receipt')];
  });
  await page.setViewportSize({ width: 390, height: 844 });
  report.mobileOverflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
  await page.screenshot({ path: `${evidence}/live-mobile.jpg`, type: 'jpeg', quality: 85 }); report.screenshots.push('live-mobile.jpg');
  report.result = report.status.includes('Updated at block') && !report.consoleErrors.length && !report.mobileOverflow ? 'PASS' : 'LIMITED';
} catch (e) { report.result = 'UNAVAILABLE'; report.error = e.message; }
finally { writeFileSync(`${evidence}/browser-live.json`, JSON.stringify(report, null, 2) + '\n'); console.log(JSON.stringify(report, null, 2)); await browser.close(); await new Promise(r => server.close(r)); }
