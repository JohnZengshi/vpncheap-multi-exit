const { test, expect } = require('playwright/test');
const { startFixture, until } = require('./consistency-harness.cjs');
test.use({ browserName: 'chromium', channel: 'msedge', headless: true });

for (const viewport of [{ width: 1440, height: 960 }, { width: 390, height: 844 }]) {
  test(`exit configuration and bound cancellation at ${viewport.width}px`, async ({ page }, testInfo) => {
    const f = await startFixture();
    try {
      await until(() => f.get('/api/nine-router/sync'), value => value.state === 'completed');
      const snapshot = await f.get('/api/snapshot');
      const first = snapshot.exits[0];
      f.state.connections.push({ id: 'protected', provider: 'fixture', priority: 1, isActive: false,
        providerSpecificData: { proxyPoolId: first.poolId } });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.setViewportSize(viewport);
      f.state.failTests = true;
      await f.post('/api/nine-router/sync', {});
      await until(() => f.get('/api/nine-router/sync'), value => value.state === 'error');
      await page.goto(f.base, { waitUntil: 'domcontentloaded' });
      await expect(page.getByText('出口已生效，代理池同步失败', { exact: true }).first()).toBeVisible();
      f.state.failTests = false;
      await page.getByRole('button', { name: '重试代理池同步', exact: true }).click();
      await expect(page.getByText('出口与代理池已完成对应', { exact: true })).toBeVisible();
      await expect(page.getByRole('table', { name: '出口节点状态' }).getByRole('row')).toHaveCount(3);
      await expect(page.getByText('历史保留', { exact: true })).toBeVisible();
      await expect(page.getByText('实际：TW Same', { exact: true })).toHaveCount(2);
      await page.getByRole('button', { name: '配置出口', exact: true }).click();
      const dialog = page.getByRole('dialog');
      await expect(dialog.getByText('已有出口', { exact: true })).toBeVisible();
      await expect(dialog.getByText('可新增节点', { exact: true })).toBeVisible();
      await expect(dialog.locator('.candidate-row')).toHaveCount(3);
      await expect(dialog.getByText(/数量已满/)).toBeVisible();
      const selected = dialog.locator('.candidate-row').filter({ hasText: first.nodeHash.slice(0, 8) });
      await selected.getByRole('checkbox').uncheck();
      await dialog.getByRole('button', { name: '应用', exact: true }).click();
      await expect(dialog.locator('#config-error')).toContainText('出口仍有连接绑定');
      await expect(dialog).toBeVisible();
      expect(f.read('exit-config.json').configId).toBe('initial');
      await page.screenshot({ path: testInfo.outputPath(`configuration-${viewport.width}.png`), fullPage: true });
      expect(errors).toEqual([]);
    } finally { await f.close(); }
  });
}
