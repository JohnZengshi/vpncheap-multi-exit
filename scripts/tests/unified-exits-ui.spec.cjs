const { test, expect } = require('playwright/test');
const { startFixture, until } = require('./consistency-harness.cjs');

test.use({ browserName: 'chromium', channel: 'msedge', headless: true });

for (const width of [1440, 390]) {
  test(`unified exit relations explain readiness and preserve history at ${width}px`, async ({ page }, testInfo) => {
    const f = await startFixture();
    try {
      await until(() => f.get('/api/nine-router/sync'), value => value.state === 'completed');
      const snapshot = await f.get('/api/snapshot');
      const [healthy, unhealthy] = snapshot.exits;
      healthy.configuredNodeName = null;
      healthy.needsReview = true;
      healthy.fallbackActive = true;
      unhealthy.healthOk = false;
      unhealthy.state = 'unhealthy';
      const failedPool = snapshot.pools.find(pool => pool.id === unhealthy.poolId);
      failedPool.testStatus = 'error';
      failedPool.isActive = false;
      snapshot.connections.push({ id: 'bound-current', provider: 'claude', poolId: healthy.poolId, isActive: false });
      snapshot.exits.push(
        { ...unhealthy, nodeHash: 'missing-unhealthy', configuredNodeName: 'Unready exit', activeNodeName: 'Unready exit',
          port: 39103, endpoint: '127.0.0.1:39103', poolId: null, poolName: null, poolState: 'missing' },
        { ...healthy, nodeHash: 'missing-healthy', configuredNodeName: 'Ready exit', activeNodeName: 'Ready exit',
          port: 39104, endpoint: '127.0.0.1:39104', poolId: null, poolName: null, poolState: 'missing' }
      );
      snapshot.poolPlan = [{ port: 39104, action: 'create' }];
      snapshot.pools.push({ id: 'external', name: 'External same port', port: healthy.port,
        endpoint: healthy.endpoint, managed: false, relationState: 'external', isActive: true });
      await page.route('**/api/snapshot', route => route.fulfill({ json: snapshot }));
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.setViewportSize({ width, height: 960 });
      await page.goto(f.base, { waitUntil: 'domcontentloaded' });
      const table = page.getByRole('table', { name: '出口节点状态' });
      await expect(page.locator('#stat-pools')).toHaveText('2/4');
      const rowFor = hash => table.getByRole('row').filter({ hasText: hash });
      await expect(table.getByRole('row')).toHaveCount(5);
      const healthyRow = rowFor(healthy.nodeHash);
      await expect(healthyRow).toContainText('线路可用');
      await expect(healthyRow).toContainText('入口已同步');
      await expect(healthyRow).toContainText('原配置待核对');
      await expect(healthyRow).toContainText('Claude');
      await expect(healthyRow).toContainText('停用');
      await expect(healthyRow).not.toContainText('External same port');
      await expect(rowFor(unhealthy.nodeHash)).toContainText('入口已同步');
      await expect(rowFor(unhealthy.nodeHash)).toContainText('重复同步无法修复线路');
      await expect(rowFor(unhealthy.nodeHash)).toContainText('池检测失败');
      await expect(rowFor('missing-unhealthy')).toContainText('未建池，等待线路恢复');
      await expect(rowFor('missing-unhealthy').getByRole('button', { name: '创建代理池' })).toHaveCount(0);
      await expect(rowFor('missing-healthy').getByRole('button', { name: '创建代理池' })).toBeVisible();
      const otherPools = page.locator('#pool-list');
      await expect(otherPools.locator('.pool-row')).toHaveCount(2);
      await expect(otherPools).toContainText('历史保留');
      await expect(otherPools).toContainText('不代表当前出口可用');
      await expect(otherPools).toContainText('External same port');
      for (const pool of snapshot.pools.filter(pool => pool.relationState === 'matched')) {
        await expect(otherPools.getByText(pool.name, { exact: true })).toHaveCount(0);
      }
      await healthyRow.getByText('查看详情', { exact: true }).click();
      await page.getByRole('button', { name: '刷新面板', exact: true }).click();
      await expect(healthyRow.locator('details')).toHaveAttribute('open', '');
      await expect(healthyRow.getByText(`PID ${healthy.workerPid}`, { exact: true })).toBeVisible();
      await expect(healthyRow.getByText(`127.0.0.1:${healthy.port}`, { exact: true })).toBeVisible();
      await expect(healthyRow.getByText('入口已同步', { exact: true })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      await page.screenshot({ path: testInfo.outputPath(`unified-${width}.png`), fullPage: true });

      await page.getByPlaceholder('节点、地区、端口', { exact: true }).fill('Claude');
      await expect(table.getByRole('row')).toHaveCount(2);
      await page.locator('#exit-search').fill('');
      healthy.poolId = null;
      healthy.poolState = 'missing';
      snapshot.poolPlan.push({ port: healthy.port, action: 'conflict', conflictReason: 'owned-address-edited' });
      await page.getByRole('button', { name: '刷新面板', exact: true }).click();
      await expect(healthyRow).toContainText('对应冲突，待核对');
      await expect(healthyRow.getByText('入口已同步', { exact: true })).toHaveCount(0);
      snapshot.warnings.push('nine-router-unavailable');
      await page.getByRole('button', { name: '刷新面板', exact: true }).click();
      await expect(healthyRow).toContainText('无法核对代理池');
      await expect(page.locator('#stat-pools')).toHaveText('待核对');
      await expect(healthyRow).toContainText('绑定信息待核对');
      await expect(healthyRow.getByText('未绑定账号', { exact: true })).toHaveCount(0);
      expect(errors).toEqual([]);
    } finally { await f.close(); }
  });
}
