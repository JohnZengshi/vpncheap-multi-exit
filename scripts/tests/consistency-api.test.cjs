const { test } = require('node:test');
const assert = require('node:assert/strict');
const { startFixture, until } = require('./consistency-harness.cjs');

test('Dashboard API preserves identity and bindings through real sync requests', { timeout: 90000 }, async t => {
  const f = await startFixture();
  t.after(() => f.close());
  const { state, get, post, read, write } = f;
  await until(() => get('/api/nine-router/sync'), value => ['completed', 'error'].includes(value.state));
  const snapshot = await get('/api/snapshot');
  assert.equal(snapshot.exits.length, 2);
  assert.equal(snapshot.candidates.length, 3);
  assert.equal(snapshot.pools.filter(pool => pool.relationState === 'matched').length, 2);
  assert.equal(snapshot.pools.find(pool => pool.id === 'historical').relationState, 'historical');
  assert.equal(state.connections[0].providerSpecificData.proxyPoolId, 'historical');
  assert.ok(snapshot.exits.every(exit => exit.configuredNodeName === 'TW Same' && exit.activeNodeName === 'TW Same'));

  const first = snapshot.exits[0];
  state.connections.push({ id: 'protected', provider: 'fixture', isActive: false, priority: 1,
    providerSpecificData: { proxyPoolId: first.poolId } });
  const removed = await post('/api/exit-config', { maxExits: 1, nodeHashes: [snapshot.exits[1].nodeHash] });
  assert.equal(removed.status, 409);
  assert.equal(removed.body.error, 'exit-has-bindings');
  assert.equal(removed.body.affected[0].connectionId, 'protected');
  assert.equal(read('exit-config.json').configId, 'initial');
  state.failReads = true;
  const unavailable = await post('/api/exit-config', { maxExits: 1, nodeHashes: [snapshot.exits[1].nodeHash] });
  assert.equal(unavailable.body.error, 'binding-check-unavailable');
  state.failReads = false;

  const apply = await post('/api/exit-config', { maxExits: 2, nodeHashes: snapshot.exits.map(exit => exit.nodeHash) });
  assert.equal(apply.status, 202);
  assert.equal((await get('/api/snapshot')).configuration.state, 'adjusting');
  const status = read('status.json');
  status.appliedConfigId = apply.body.configId;
  status.updatedAt = new Date().toISOString();
  write('status.json', status);
  assert.equal((await get('/api/snapshot')).configuration.state, 'syncing');
  state.failTests = true;
  const failed = await post('/api/nine-router/sync', {});
  assert.equal(failed.status, 202);
  await until(() => get('/api/nine-router/sync'), value => value.configId === apply.body.configId && value.state === 'error');
  assert.equal((await get('/api/snapshot')).configuration.state, 'sync-error');
  const count = state.pools.length;
  state.failTests = false;
  await post('/api/nine-router/sync', {});
  await until(() => get('/api/nine-router/sync'), value => value.configId === apply.body.configId && value.state === 'completed');
  assert.equal(state.pools.length, count);
  assert.equal((await get('/api/snapshot')).configuration.state, 'completed');
  assert.equal(read('status.json').exits.length, 2);
  assert.equal(state.connections.find(item => item.id === 'protected').providerSpecificData.proxyPoolId, first.poolId);
  state.pools.find(pool => pool.id === first.poolId).proxyUrl = `https://127.0.0.1:${first.port}`;
  const conflict = await until(() => get('/api/snapshot'), value => value.pools.find(pool => pool.id === first.poolId).relationState === 'conflict');
  assert.equal(conflict.exits.find(exit => exit.nodeHash === first.nodeHash).poolId, null);
  assert.notEqual(conflict.connections.find(item => item.id === 'protected').routeState, '关系完整');
  write('9router-sync-status.json', { state: 'running', pid: 2147483647,
    configId: apply.body.configId, instanceId: status.instanceId });
  assert.equal((await get('/api/snapshot')).configuration.state, 'sync-error');
});

test('newly healthy exits automatically receive pools after initial synchronization', { timeout: 45000 }, async t => {
  const f = await startFixture({ initiallyHealthy: false });
  t.after(() => f.close());
  await until(() => f.get('/api/nine-router/sync'), value => value.state === 'completed');
  assert.equal(f.state.created, 0);
  const status = f.read('status.json');
  status.exits.forEach(exit => { exit.healthOk = true; exit.state = 'healthy'; });
  status.updatedAt = new Date().toISOString();
  f.write('status.json', status);
  const snapshot = await until(() => f.get('/api/snapshot'), value => value.exits.every(exit => exit.poolId));
  assert.equal(snapshot.configuration.state, 'completed');
  assert.equal(f.state.created, 2);
});

test('Broker rechecks binding created after configuration was saved', { timeout: 45000 }, async t => {
  const f = await startFixture();
  t.after(() => f.close());
  const snapshot = await until(() => f.get('/api/snapshot'), value => value.exits.every(exit => exit.poolId));
  const removed = snapshot.exits[0];
  const available = snapshot.candidates.find(candidate => !candidate.selected);
  const saved = await f.post('/api/exit-config', { maxExits: 2, nodeHashes: [snapshot.exits[1].nodeHash, available.nodeHash] });
  assert.equal(saved.status, 202);
  f.state.connections.push({ id: 'late-binding', provider: 'fixture', isActive: false,
    providerSpecificData: { proxyPoolId: removed.poolId } });
  const execution = await f.runBroker();
  assert.equal(execution.code, 1, execution.output);
  assert.match(execution.output, /exit-has-bindings/);
  assert.ok(f.read('status.json').exits.some(exit => exit.nodeHash === removed.nodeHash));
  assert.equal(f.read('status.json').appliedConfigId, 'initial');
});
