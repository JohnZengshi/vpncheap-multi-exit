const { test, expect } = require('playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });
test.setTimeout(60000);

test('exports configured VPNCheap servers through the actual dashboard button', async ({ page }, testInfo) => {
  const root = path.resolve(__dirname, '../..');
  const readRuntime = () => {
    const status = JSON.parse(fs.readFileSync(path.join(root, 'runtime/status.json'), 'utf8'));
    return {
      brokerPid: status.brokerPid,
      exits: status.exits.map(({ nodeHash, port, workerPid }) => ({ nodeHash, port, workerPid }))
        .sort((a, b) => a.port - b.port)
    };
  };
  const before = readRuntime();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/', { waitUntil: 'domcontentloaded' });
  const button = page.getByRole('button', { name: /导出.*服务器/ });
  await expect(button).toBeVisible();
  const responsePromise = page.waitForResponse(response => new URL(response.url()).pathname === '/api/exit-ip-export');
  const downloadPromise = page.waitForEvent('download');
  await button.click();
  const response = await responsePromise;
  expect(response.status()).toBe(200);
  const payload = await response.json();
  console.log(JSON.stringify({
    apiFields: Object.keys(payload.exits[0] || {}),
    rows: payload.exits.length,
    missingServerAddresses: payload.exits.filter(row => !row.serverAddress || !row.serverPort).length
  }));
  const download = await downloadPromise;
  const file = testInfo.outputPath(download.suggestedFilename());
  await download.saveAs(file);
  const parsed = JSON.parse(execFileSync('pwsh.exe', [
    '-NoProfile', '-Command',
    'Import-Csv -LiteralPath $env:EXPORT_TEST_CSV | ConvertTo-Json -AsArray -Compress'
  ], { encoding: 'utf8', env: { ...process.env, EXPORT_TEST_CSV: file } }));
  expect(parsed).toHaveLength(before.exits.length);
  expect(fs.readFileSync(file, 'utf8')).not.toContain('127.0.0.1');
  for (let i = 0; i < parsed.length; i++) {
    expect(parsed[i]['VPNCheap 服务器 IP/地址'], `CSV row ${i + 1} server address`).toBeTruthy();
    expect(Number(parsed[i]['服务器端口']), `CSV row ${i + 1} server port`).toBeGreaterThan(0);
    expect(Number(parsed[i]['服务器端口'])).toBeLessThanOrEqual(65535);
    expect(parsed[i]['VPNCheap 服务器 IP/地址']).toBe(payload.exits[i].serverAddress);
    expect(Number(parsed[i]['服务器端口'])).toBe(payload.exits[i].serverPort);
  }
  await expect(button).toBeEnabled();
  expect(errors).toEqual([]);
  expect(readRuntime()).toEqual(before);
  console.log(`PASS browser download: ${parsed.length} nonempty servers; broker, workers and ports unchanged`);
});
