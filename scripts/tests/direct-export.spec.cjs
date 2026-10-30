const { test, expect } = require('playwright/test');

const baseURL = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';
test.use({ browserName: 'chromium', channel: 'msedge', headless: true });

async function readDownload(download) {
  const stream = await download.createReadStream();
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

for (const width of [1280, 390]) {
  test(`DIRECT download preserves order and duplicates at width ${width}`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/exit-ip-export', route => route.fulfill({ json: {
      exits: [
        { serverAddress: '34.104.159.200', serverPort: 443 },
        { serverAddress: '54.95.10.160', serverPort: 8443 },
        { serverAddress: '34.104.159.200', serverPort: null },
        { serverAddress: '' },
        { serverAddress: 'example.test' },
        { serverAddress: '999.1.1.1' }
      ]
    } }));
    await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
    const button = page.getByRole('button', { name: '导出 DIRECT 规则', exact: true });
    await expect(button).toBeVisible();
    const pending = page.waitForEvent('download');
    await button.click();
    const download = await pending;
    expect(download.suggestedFilename()).toMatch(/^vpncheap-direct-rules-.*\.txt$/);
    expect(await readDownload(download)).toBe(
      '- IP-CIDR,34.104.159.200,DIRECT\r\n- IP-CIDR,54.95.10.160,DIRECT\r\n- IP-CIDR,34.104.159.200,DIRECT\r\n'
    );
    await expect(page.getByText('已导出 3 条 DIRECT 规则，跳过 3 个缺失或非 IPv4 地址', { exact: true })).toBeVisible();
    await expect(button).toBeEnabled();
    await expect(page.getByRole('button', { name: /导出.*服务器/ })).toBeEnabled();
    const bounds = await button.boundingBox();
    expect(bounds.x).toBeGreaterThanOrEqual(0);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
    await page.screenshot({ path: testInfo.outputPath(`direct-${width}.png`), fullPage: true });
    expect(errors).toEqual([]);
  });
}

test('DIRECT empty address error allows a subsequent CSV download', async ({ page }) => {
  await page.route('**/api/exit-ip-export', route => route.fulfill({ json: {
    exits: [{ nodeName: 'Fixture', serverAddress: '', serverPort: 443 }]
  } }));
  await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
  const button = page.getByRole('button', { name: '导出 DIRECT 规则', exact: true });
  await button.click();
  await expect(page.getByText('没有可导出的 IPv4 服务器地址', { exact: true })).toBeVisible();
  await expect(button).toBeEnabled();
  const pending = page.waitForEvent('download');
  await page.getByRole('button', { name: /导出.*服务器/ }).click();
  const download = await pending;
  expect(download.suggestedFilename()).toMatch(/\.csv$/);
  expect(await readDownload(download)).toContain('Fixture');
});
