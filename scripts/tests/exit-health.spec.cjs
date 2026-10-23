const { test, expect } = require('playwright/test');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });
test.setTimeout(90000);

function probe(port, url) {
  return new Promise(resolve => {
    execFile('curl.exe', ['-q', '-sS', '-o', 'NUL', '-w', '%{http_code}|%{time_total}',
      '--max-time', '8', '--noproxy', '', '-x', `http://127.0.0.1:${port}`, url],
    { timeout: 10000, windowsHide: true }, (error, stdout) => {
      const [status, seconds] = stdout.trim().split('|');
      resolve({ target: new URL(url).hostname, status, ms: Math.round(Number(seconds) * 1000),
        exitCode: error ? error.code : 0, ok: !error && ['200', '204'].includes(status) });
    });
  });
}

test('live exit connectivity across independent targets without control mutations', async ({ page }, testInfo) => {
  const readIdentity = () => {
    const status = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../runtime/status.json'), 'utf8'));
    return { brokerPid: status.brokerPid,
      exits: status.exits.map(({ nodeHash, port, workerPid }) => ({ nodeHash, port, workerPid }))
        .sort((a, b) => a.port - b.port) };
  };
  const before = readIdentity();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const url = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  const table = page.getByRole('table', { name: '出口节点状态', exact: true });
  await expect(table.getByRole('row')).toHaveCount(10);
  const response = await page.request.get(new URL('/api/snapshot', url).href);
  expect(response.ok()).toBeTruthy();
  const snapshot = await response.json();
  const results = await Promise.all(snapshot.exits.map(async exit => {
    const probes = [];
    for (const target of ['https://cp.cloudflare.com/generate_204',
      'https://www.gstatic.com/generate_204', 'https://api.ipify.org']) {
      probes.push(await probe(exit.port, target));
    }
    return { port: exit.port, state: exit.state, healthOk: exit.healthOk, probes };
  }));
  const report = { checkedAt: new Date().toISOString(), results };
  fs.writeFileSync(testInfo.outputPath('connectivity.json'), JSON.stringify(report, null, 2));
  await page.screenshot({ path: testInfo.outputPath('dashboard.png'), fullPage: true });
  for (const result of results) {
    console.log(`${result.port} dashboard=${result.state} ` +
      result.probes.map(p => `${p.target}=${p.status}/${p.exitCode}/${p.ms}ms`).join(' '));
    expect.soft(result.probes.some(p => p.ok), `port ${result.port}: no external target reachable`).toBeTruthy();
  }
  expect(errors).toEqual([]);
  expect(readIdentity()).toEqual(before);
});
