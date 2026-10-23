const { test, expect } = require('playwright/test');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });
const duration = Number(process.env.MONITOR_SECONDS || 300);
test.setTimeout((duration + 90) * 1000);
const root = path.resolve(__dirname, '../..');
const targets = ['https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204'];
const fields = ['port', 'nodeHash', 'workerPid', 'state', 'healthOk', 'httpStatus',
  'latencyMs', 'lastCheckAt', 'lastHealthyAt', 'consecutiveFailures', 'healthTarget',
  'recoveryAttempt', 'recoveryState', 'recoveryErrorHash', 'nextRecoveryAt', 'updatedAt'];
const select = value => Object.fromEntries(fields.map(key => [key, value[key] ?? null]));
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const identity = value => value.exits.map(e => [e.port, e.nodeHash, e.workerPid])
  .sort((a, b) => a[0] - b[0]);

function probe(port, url) {
  return new Promise(resolve => {
    const startedAt = new Date().toISOString();
    execFile('curl.exe', ['-q', '-sS', '-o', 'NUL', '-w',
      '%{http_code}|%{time_total}|%{time_connect}|%{time_appconnect}',
      '--max-time', '8', '--noproxy', port ? '' : '*',
      ...(port ? ['-x', `http://127.0.0.1:${port}`] : []), url],
    { timeout: 10000, windowsHide: true }, (error, stdout) => {
      const [status, total, connect, tls] = stdout.trim().split('|');
      resolve({ startedAt, port: port || 'direct', target: new URL(url).hostname,
        status, ms: Math.round(Number(total) * 1000),
        connectMs: Math.round(Number(connect) * 1000),
        tlsMs: Math.round(Number(tls) * 1000), exitCode: error ? error.code : 0,
        ok: !error && ['200', '204'].includes(status) });
    });
  });
}

test('bounded read-only observation preserves outage evidence @monitor', async ({ page, request }, testInfo) => {
  const url = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';
  const initial = readJson(path.join(root, 'runtime/status.json'));
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  // Safety boundary: even an accidental UI interaction cannot mutate the service.
  await page.route('**/api/**', route => route.request().method() === 'GET'
    ? route.continue() : route.abort('blockedbyclient'));
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  const table = page.getByRole('table', { name: '出口节点状态', exact: true });
  await expect(table.getByRole('row')).toHaveCount(initial.exits.length + 1);
  const samples = [];
  const start = Date.now();
  let previousSignature = '';
  await expect.poll(async () => {
    const response = await request.get(new URL('/api/snapshot', url).href);
    expect(response.ok()).toBeTruthy();
    const snapshot = await response.json();
    const workers = initial.exits.map(exit => select(readJson(
      path.join(root, 'runtime/workers', `${exit.nodeHash}.json`))));
    const probes = await Promise.all([null, ...initial.exits.map(e => e.port)]
      .flatMap(port => targets.map(target => probe(port, target))));
    const sample = { checkedAt: new Date().toISOString(),
      workers, dashboard: snapshot.exits.map(select), probes };
    samples.push(sample);
    fs.appendFileSync(testInfo.outputPath('samples.jsonl'), JSON.stringify(sample) + '\n');
    const healthy = workers.filter(e => e.healthOk).length;
    const passed = probes.filter(p => p.port !== 'direct' && p.ok).length;
    const direct = probes.filter(p => p.port === 'direct' && p.ok).length;
    console.log(`${sample.checkedAt} health=${healthy}/${workers.length} ` +
      `proxy=${passed}/${workers.length * 2} direct=${direct}/2 ` +
      workers.map(e => `${e.port}:${e.recoveryState || e.state}:${e.recoveryAttempt}`).join(' '));
    const signature = workers.map(e => `${e.state}:${e.recoveryState}`).join('|');
    if (signature !== previousSignature) {
      await page.screenshot({ path: testInfo.outputPath(`round-${samples.length}.png`), fullPage: true });
      previousSignature = signature;
    }
    expect.soft(identity(readJson(path.join(root, 'runtime/status.json'))),
      'production selections and worker PIDs must stay unchanged').toEqual(identity(initial));
    return Date.now() - start >= duration * 1000;
  }, { timeout: (duration + 30) * 1000, intervals: [15000] }).toBeTruthy();
  const outageSamples = samples.filter(s => s.probes.some(p => p.port !== 'direct' && !p.ok));
  const summary = { startedAt: new Date(start).toISOString(), finishedAt: new Date().toISOString(),
    rounds: samples.length, outageRounds: outageSamples.length,
    requests: samples.flatMap(s => s.probes).length,
    proxyFailures: samples.flatMap(s => s.probes).filter(p => p.port !== 'direct' && !p.ok).length,
    directFailures: samples.flatMap(s => s.probes).filter(p => p.port === 'direct' && !p.ok).length,
    identityUnchanged: JSON.stringify(identity(initial)) ===
      JSON.stringify(identity(readJson(path.join(root, 'runtime/status.json')))),
    pageErrors: errors };
  fs.writeFileSync(testInfo.outputPath('summary.json'), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary));
  expect(errors).toEqual([]);
  expect.soft(summary.proxyFailures, 'live failures are evidence, not a stability pass').toBe(0);
});
