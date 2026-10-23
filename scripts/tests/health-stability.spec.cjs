const { test, expect } = require('playwright/test');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');
const run = promisify(execFile);
const root = path.resolve(__dirname, '../..');
const baseURL = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });
test.setTimeout(60000);

function runtimeIdentity() {
  const status = JSON.parse(fs.readFileSync(path.join(root, 'runtime/status.json'), 'utf8'));
  return {
    brokerPid: status.brokerPid,
    exits: status.exits.map(({ nodeHash, port, workerPid }) => ({ nodeHash, port, workerPid }))
      .sort((a, b) => a.port - b.port)
  };
}

async function healthTransitions() {
  const { stdout } = await run('pwsh.exe', ['-NoProfile', '-File',
    path.join(__dirname, 'health-regression.ps1'), '-Json'],
  { timeout: 30000, windowsHide: true, encoding: 'utf8' });
  const result = stdout.split(/\r?\n/).find(line => line.startsWith('HEALTH-RESULT:'));
  expect(result, stdout).toBeTruthy();
  return JSON.parse(result.slice('HEALTH-RESULT:'.length));
}

test('health and recovery production code passes injected faults', async () => {
  const before = runtimeIdentity();
  try {
    const states = await healthTransitions();
    expect(states.healthy).toMatchObject({ healthOk: true, exitIpOk: false, recoveryAttempt: 0 });
    expect(states['stage-fails']).toMatchObject({ healthOk: false, recoveryState: 'validation-failed' });
    expect(states['lock-busy']).toMatchObject({ healthOk: false, recoveryState: 'update-pending' });
    expect(states.recovered).toMatchObject({ healthOk: false, recoveryState: 'updated' });
    expect(states.fallback).toMatchObject({
      healthOk: false, recoveryState: 'updated', fallbackActive: true,
      protocol: 'anytls', activeNodeName: 'HK-backup', serverAddress: '192.0.2.2', serverPort: 8443
    });
  } finally {
    expect(runtimeIdentity()).toEqual(before);
  }
});

test('dashboard distinguishes metadata failure, outage and verified recovery', async ({ page, request }, testInfo) => {
  const before = runtimeIdentity();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  try {
    const response = await request.get(new URL('/api/snapshot', baseURL).href);
    await expect(response).toBeOK();
    const snapshot = await response.json();
    expect(snapshot.exits).toHaveLength(9);
    const states = await healthTransitions();
    const original = snapshot.exits[0];
    let state = 'healthy';
    // Exercise the edited assets, even when the running dashboard uses an older bundle.
    await page.route('**/app.js', route => route.fulfill({
      contentType: 'application/javascript', body: fs.readFileSync(path.join(root, 'dashboard/app.js'), 'utf8')
    }));
    await page.route('**/api/snapshot', route => {
      const exit = { ...original, ...states[state], processAlive: true };
      return route.fulfill({ json: { ...snapshot, exits: [exit] } });
    });
    await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
    const table = page.getByRole('table', { name: '出口节点状态', exact: true });
    const row = table.getByRole('row').filter({ hasText: original.nodeHash });
    await expect(row.getByText('健康', { exact: true })).toBeVisible();
    await expect(row.getByText('IP 查询暂不可用', { exact: true })).toBeVisible();
    await expect(row).toHaveAttribute('data-tone', 'ok');

    for (const [next, label] of [
      ['transient', '连接波动'],
      ['schedule', '等待恢复验证'],
      ['stage-fails', '恢复验证未通过'],
      ['lock-busy', '等待恢复锁'],
      ['recovered', '已重建，等待复检'],
      ['fallback', '已重建，等待复检'],
      ['healthy', '健康']
    ]) {
      state = next;
      const refreshed = page.waitForResponse(r => new URL(r.url()).pathname === '/api/snapshot');
      await page.getByRole('button', { name: '刷新面板', exact: true }).click();
      await refreshed;
      await expect(row.getByText(label, { exact: true })).toBeVisible();
      await expect(row).toHaveAttribute('data-tone', next === 'healthy' ? 'ok' : 'bad');
      if (next !== 'healthy') {
        await expect(row.getByText('健康', { exact: true })).toHaveCount(0);
      }
      if (next === 'fallback') {
        await expect(row.getByText('anytls', { exact: true })).toBeVisible();
        await expect(row.getByText('备用 · HK-backup', { exact: true })).toBeVisible();
        await expect(row.getByText('192.0.2.2:8443', { exact: true })).toBeVisible();
      }
    }
    await page.screenshot({ path: testInfo.outputPath('metadata-warning.png'), fullPage: true });
    expect(errors).toEqual([]);
  } finally {
    expect(runtimeIdentity()).toEqual(before);
  }
});

test('CSV download describes the applied backup, not the original selection', async ({ page }, testInfo) => {
  const before = runtimeIdentity();
  try {
    const { stdout } = await run('pwsh.exe', ['-NoProfile', '-File',
      path.join(__dirname, 'server-export-regression.ps1'), '-Json'],
    { timeout: 30000, windowsHide: true, encoding: 'utf8' });
    const framed = stdout.split(/\r?\n/).find(line => line.startsWith('SERVER-EXPORT-RESULT:'));
    expect(framed, stdout).toBeTruthy();
    const payload = JSON.parse(framed.slice('SERVER-EXPORT-RESULT:'.length));
    expect(payload.exits[0]).toMatchObject({
      nodeName: 'Backup', protocol: 'anytls', serverAddress: '192.0.2.2', serverPort: 8443
    });
    await page.route('**/app.js', route => route.fulfill({
      contentType: 'application/javascript', body: fs.readFileSync(path.join(root, 'dashboard/app.js'), 'utf8')
    }));
    await page.route('**/api/exit-ip-export', route => route.fulfill({ json: payload }));
    await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
    const downloaded = page.waitForEvent('download');
    await page.getByRole('button', { name: /导出.*服务器/ }).click();
    const download = await downloaded;
    const file = testInfo.outputPath('applied-backup.csv');
    await download.saveAs(file);
    const csv = fs.readFileSync(file, 'utf8');
    for (const field of ['Backup', 'anytls', '192.0.2.2', '8443']) expect(csv).toContain(field);
    for (const field of ['127.0.0.1', 'never-export-this', 'hysteria2']) expect(csv).not.toContain(field);
  } finally {
    expect(runtimeIdentity()).toEqual(before);
  }
});
