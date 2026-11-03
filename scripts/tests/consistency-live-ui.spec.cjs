const { test, expect } = require('playwright/test');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });

for (const viewport of [{ width: 1440, height: 960 }, { width: 390, height: 844 }]) {
  test(`live exit and pool relations remain readable at ${viewport.width}px`, async ({ page }, testInfo) => {
    const base = process.env.DASHBOARD_URL || 'http://127.0.0.1:39080/';
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize(viewport);
    await page.goto(base, { waitUntil: 'domcontentloaded' });
    const response = await page.request.get(new URL('/api/snapshot', base).href);
    expect(response.ok()).toBeTruthy();
    const snapshot = await response.json();
    const table = page.getByRole('table', { name: '出口节点状态', exact: true });
    await expect(table.getByRole('row')).toHaveCount(snapshot.exits.length + 1);
    for (const exit of snapshot.exits) {
      const row = table.getByRole('row').filter({ hasText: exit.nodeHash });
      await expect(row).toContainText(exit.configuredNodeName || '原配置待核对');
      await expect(row).toContainText(`实际：${exit.activeNodeName || '待确认'}`);
    }
    for (const pool of snapshot.pools.filter(pool => pool.relationState === 'historical')) {
      await expect(page.getByText(pool.name, { exact: true }).first()).toBeVisible();
    }
    await page.screenshot({ path: testInfo.outputPath(`live-${viewport.width}.png`), fullPage: true });
    await page.getByRole('button', { name: '配置出口', exact: true }).click();
    await expect(page.getByRole('dialog').locator('.candidate-row')).toHaveCount(snapshot.candidates.length);
    await expect(page.getByRole('dialog').getByText('自动选取', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: '取消', exact: true }).click();
    expect(errors).toEqual([]);
  });
}
