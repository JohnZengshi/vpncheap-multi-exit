const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');

async function until(read, accept, timeout = 25000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try { last = await read(); if (accept(last)) return last; } catch (error) { last = error.message; }
    await new Promise(resolve => setTimeout(resolve, 150));
  }
  throw new Error(`Timed out: ${JSON.stringify(last)}`);
}

async function startFixture({ initiallyHealthy = true } = {}) {
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), 'vpncheap-api-'));
  fs.mkdirSync(path.join(runtime, 'auth'));
  fs.writeFileSync(path.join(runtime, 'machine-id'), 'fixture-machine');
  fs.writeFileSync(path.join(runtime, 'auth/cli-secret'), 'fixture-secret');
  execFileSync('pwsh', ['-NoProfile', '-File', path.join(__dirname, 'consistency-fixture.ps1'),
    '-RuntimeDirectory', runtime, '-OwnerPid', String(process.pid)], { windowsHide: true, stdio: 'pipe' });
  if (!initiallyHealthy) {
    const file = path.join(runtime, 'status.json');
    const status = JSON.parse(fs.readFileSync(file, 'utf8'));
    status.exits.forEach(exit => { exit.healthOk = false; exit.state = 'starting'; });
    fs.writeFileSync(file, JSON.stringify(status));
  }
  const state = {
    failTests: false, failReads: false, created: 0,
    pools: [{ id: 'historical', name: 'vpncheap-TW Same', proxyUrl: 'http://127.0.0.1:39991', type: 'http',
      strictProxy: true, isActive: true, testStatus: 'active', boundConnectionCount: 1 }],
    connections: [{ id: 'inactive', provider: 'fixture', priority: 1, isActive: false,
      providerSpecificData: { proxyPoolId: 'historical' } }]
  };
  const mock = http.createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    const url = new URL(req.url, 'http://localhost');
    const parts = url.pathname.split('/').filter(Boolean);
    const send = (value, code = 200) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (!req.headers['x-9r-cli-token']) return send({}, 401);
    if (state.failReads && req.method === 'GET') return send({}, 503);
    if (parts[1] === 'providers') {
      if (req.method === 'GET') return send({ connections: state.connections });
      const connection = state.connections.find(item => item.id === parts[2]);
      if (!connection) return send({}, 404);
      connection.providerSpecificData.proxyPoolId = body.proxyPoolId;
      return send({ connection });
    }
    if (parts[1] !== 'proxy-pools') return send({}, 404);
    if (req.method === 'GET') return send({ proxyPools: state.pools });
    if (req.method === 'POST' && !parts[2]) {
      const pool = { ...body, id: `created-${++state.created}`, testStatus: 'unknown', boundConnectionCount: 0 };
      state.pools.push(pool);
      return send({ proxyPool: pool });
    }
    const pool = state.pools.find(item => item.id === parts[2]);
    if (!pool) return send({}, 404);
    if (parts[3] === 'test') { pool.testStatus = state.failTests ? 'error' : 'active'; return send({ testStatus: pool.testStatus }); }
    if (req.method === 'PUT') { Object.assign(pool, body); return send({ proxyPool: pool }); }
    if (req.method === 'DELETE') { state.pools = state.pools.filter(item => item !== pool); return send({ ok: true }); }
    return send({}, 405);
  });
  await new Promise(resolve => mock.listen(0, '127.0.0.1', resolve));
  const portProbe = http.createServer();
  await new Promise(resolve => portProbe.listen(0, '127.0.0.1', resolve));
  const port = portProbe.address().port;
  await new Promise(resolve => portProbe.close(resolve));
  const env = { ...process.env, VPNCHEAP_NINE_ROUTER_URL: `http://127.0.0.1:${mock.address().port}`,
    VPNCHEAP_NINE_ROUTER_DATA: runtime };
  const server = spawn('pwsh', ['-NoProfile', '-File', path.join(root, 'scripts/dashboard.ps1'), '-Action', 'run',
    '-Port', String(port), '-RuntimeDirectory', runtime], { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  server.stdout.on('data', chunk => { output += chunk; });
  server.stderr.on('data', chunk => { output += chunk; });
  const base = `http://127.0.0.1:${port}`;
  const get = async route => {
    let response;
    try { response = await fetch(base + route); }
    catch (error) { throw new Error(`${error.message}; dashboard exit=${server.exitCode}; ${output}`); }
    assert.equal(response.status, 200, route);
    return response.json();
  };
  const post = async (route, body) => {
    const response = await fetch(base + route, { method: 'POST', headers: {
      'Content-Type': 'application/json', 'X-Exit-Control': '1', Origin: base
    }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const read = name => JSON.parse(fs.readFileSync(path.join(runtime, name), 'utf8'));
  const write = (name, value) => {
    const file = path.join(runtime, name); fs.writeFileSync(file + '.test-tmp', JSON.stringify(value));
    fs.renameSync(file + '.test-tmp', file);
  };
  const runBroker = () => new Promise((resolve, reject) => {
    const broker = spawn('pwsh', ['-NoProfile', '-File', path.join(root, 'scripts/broker.ps1'),
      '-Action', 'run', '-RuntimeDirectory', runtime], { env, windowsHide: true });
    let output = '';
    broker.stdout.on('data', data => { output += data; });
    broker.stderr.on('data', data => { output += data; });
    broker.on('error', reject);
    broker.on('exit', code => resolve({ code, output }));
  });
  async function close() {
    if (server.exitCode === null) { server.kill(); await new Promise(resolve => server.once('exit', resolve)); }
    const syncFile = path.join(runtime, '9router-sync-status.json');
    if (fs.existsSync(syncFile)) {
      const sync = read('9router-sync-status.json');
      if (sync.state === 'running' && sync.pid) {
        await until(() => read('9router-sync-status.json'), value => value.state !== 'running').catch(() => {
          try { process.kill(sync.pid); } catch {}
        });
      }
    }
    await new Promise(resolve => mock.close(resolve));
    fs.rmSync(runtime, { recursive: true, force: true });
  }
  try {
    await until(() => get('/api/health'), value => value.ok || value.status === 'ok');
  } catch (error) { await close(); throw new Error(`${error.message}\n${output}`); }
  return { state, runtime, base, get, post, read, write, runBroker, close, until };
}
module.exports = { startFixture, until };
