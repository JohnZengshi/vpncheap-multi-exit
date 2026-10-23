const { test, expect } = require('playwright/test');
const fs = require('node:fs');
const path = require('node:path');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });
test.setTimeout(300000);

function processes() {
  const status = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../runtime/status.json'), 'utf8'));
  return {
    brokerPid: status.brokerPid,
    exits: status.exits.map(({ nodeHash, port, workerPid }) => ({ nodeHash, port, workerPid }))
      .sort((a, b) => a.port - b.port)
  };
}

test('manual pool sync completes without restarting exits or growing the pool list', async ({ page }, testInfo) => {
  const before = processes();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const url = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  const button = page.getByRole('button', { name: '同步代理池', exact: true });
  await expect(button).toBeVisible();
  const beforeResponse = await page.request.get(new URL('/api/snapshot', url).href);
  const beforeSnapshot = await beforeResponse.json();
  const responsePromise = page.waitForResponse(response =>
    new URL(response.url()).pathname === '/api/nine-router/sync' && response.request().method() === 'POST');
  await button.click();
  const acceptedResponse = await responsePromise;
  expect(acceptedResponse.status()).toBe(202);
  const accepted = await acceptedResponse.json();
  await expect(button).toBeDisabled();
  await expect.poll(async () => {
    const response = await page.request.get(new URL('/api/nine-router/sync', url).href);
    expect(response.ok()).toBeTruthy();
    const state = await response.json();
    if (Date.parse(state.updatedAt) < Date.parse(accepted.startedAt)) return 'pending';
    return state.state;
  }, { timeout: 240000, intervals: [1000, 2000, 5000] }).toBe('completed');
  await expect(button).toBeEnabled({ timeout: 15000 });
  const afterResponse = await page.request.get(new URL('/api/snapshot', url).href);
  const after = await afterResponse.json();
  expect(after.pools.length).toBeLessThanOrEqual(beforeSnapshot.pools.length);
  const selectedPorts = new Set(before.exits.map(exit => exit.port));
  for (const pool of after.pools.filter(pool => pool.managed)) {
    expect(selectedPorts.has(pool.port) || pool.boundConnectionCount > 0).toBeTruthy();
  }
  expect(processes()).toEqual(before);
  expect(errors).toEqual([]);
  await page.screenshot({ path: testInfo.outputPath('pool-sync.png'), fullPage: true });
  console.log(`PASS actual sync button: ${after.pools.length} pools; broker and ${before.exits.length} exits unchanged`);
});
