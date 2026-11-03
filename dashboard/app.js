'use strict';

const REFRESH_MS = 5000;
const MAX_HISTORY = 60;
const SVG_NS = 'http://www.w3.org/2000/svg';
const AUTO_KEY = 'exit-control.auto-refresh';

const STATE_LABELS = {
  healthy: '健康',
  unhealthy: '异常',
  degraded: '连接波动',
  starting: '启动中',
  stopped: '已停止',
  quarantined: '已隔离',
  'port-conflict': '端口被占用',
  restarting: '等待重启',
  running: '运行中',
  pending: '等待中'
};

const PROCESS_LABELS = {
  running: '运行中',
  starting: '启动中',
  exited: '已退出',
  'restart-pending': '等待重试',
  stopped: '已停止'
};

const TASK_LABELS = {
  Ready: '就绪',
  Running: '运行中',
  Disabled: '已禁用',
  Queued: '排队中',
  Unknown: '未知'
};

const WARNING_LABELS = {
  'broker-status-missing': '未找到 Broker 状态文件',
  'broker-not-running': 'Broker 未运行',
  'task-not-running': '计划任务未运行',
  'task-unavailable': '计划任务不可用',
  'nine-router-unavailable': '9Router 接口不可用',
  'exit-degraded': '部分出口异常',
  'catalog-refresh-error': '节点目录刷新失败',
  'api-offline': '无法连接本地服务'
};

const ui = {
  data: null,
  error: null,
  loading: true,
  filter: 'all',
  poolBusy: false,
  poolPending: new Set(),
  exportBusy: false,
  subscriptionPosting: false,
  subscriptionError: '',
  subscriptionCooldownUntil: 0,
  subscriptionTimer: null,
  subscriptionWatchUntil: 0,
  query: '',
  auto: readAutoPreference(),
  history: new Map(),
  expandedExits: new Set(),
  timer: null,
  inflight: false,
  fetchedAt: null,
  toastTimer: null,
  config: {
    maxExits: 2,
    auto: true,
    selected: new Set(),
    query: '',
    saving: false
  }
};

const clockFormat = new Intl.DateTimeFormat('zh-CN', {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23'
});

function byId(id) {
  return document.getElementById(id);
}

function readAutoPreference() {
  try {
    const stored = window.localStorage.getItem(AUTO_KEY);
    return stored === null ? true : stored === '1';
  } catch (error) {
    return true;
  }
}

function saveAutoPreference(value) {
  try {
    window.localStorage.setItem(AUTO_KEY, value ? '1' : '0');
  } catch (error) {
    /* Storage can be unavailable in hardened profiles. */
  }
}

function make(tag, className, text) {
  const node = document.createElement(tag);
  if (className) {
    node.className = className;
  }
  if (text !== undefined && text !== null) {
    node.textContent = String(text);
  }
  return node;
}

function makeIcon(name, className) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', className || 'icon');
  svg.setAttribute('aria-hidden', 'true');
  const use = document.createElementNS(SVG_NS, 'use');
  use.setAttribute('href', `#i-${name}`);
  svg.appendChild(use);
  return svg;
}

function setText(id, value) {
  const node = byId(id);
  if (node) {
    node.textContent = value;
  }
}

function shortId(value, length) {
  const text = String(value || '');
  if (!text) {
    return '—';
  }
  return text.slice(0, length || 8);
}

function providerLabel(provider) {
  if (!provider) {
    return '未知通道';
  }
  if (provider === 'codex') {
    return 'Codex';
  }
  if (provider === 'claude') {
    return 'Claude';
  }
  if (provider === 'openrouter') {
    return 'OpenRouter';
  }
  const match = /^openai-compatible-([a-z]+)-/i.exec(provider);
  if (match) {
    const suffix = provider.replace(/-/g, '').slice(-6);
    return `兼容通道 · ${match[1]} · ${suffix}`;
  }
  return provider;
}

function badge(text, tone) {
  return make('span', `badge${tone ? ` badge-${tone}` : ''}`, text);
}

function chip(text, tone, extraClass) {
  return make('span', `chip${tone ? ` chip-${tone}` : ''}${extraClass ? ` ${extraClass}` : ''}`, text);
}

function exitTone(exit) {
  if (!exit.processAlive) {
    return 'bad';
  }
  if (exit.state === 'starting') {
    return 'warn';
  }
  if (exit.healthOk && exit.state === 'healthy') {
    return 'ok';
  }
  return 'bad';
}

function exitStateLabel(exit) {
  if (!exit.processAlive) {
    return '进程退出';
  }
  if (exit.state === 'starting') {
    return '启动中';
  }
  if (exit.healthOk && exit.state === 'healthy') {
    return '健康';
  }
  return STATE_LABELS[exit.state] || exit.state || '异常';
}

function formatClock(value) {
  const time = Date.parse(value);
  if (!Number.isFinite(time)) {
    return '—';
  }
  return clockFormat.format(new Date(time));
}

function formatRelative(value) {
  const time = Date.parse(value);
  if (!Number.isFinite(time)) {
    return '';
  }
  const seconds = Math.max(0, Math.round((Date.now() - time) / 1000));
  if (seconds < 5) {
    return '刚刚';
  }
  if (seconds < 60) {
    return `${seconds} 秒前`;
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }
  const hours = Math.floor(minutes / 60);
  return `${hours} 小时前`;
}

function formatUptime(value) {
  const started = Date.parse(value);
  if (!Number.isFinite(started)) {
    return '—';
  }
  const totalSeconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (days > 0) {
    return `${days} 天 ${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
  }
  if (hours > 0) {
    return `${hours} 小时 ${minutes} 分`;
  }
  if (minutes > 0) {
    return `${minutes} 分 ${seconds} 秒`;
  }
  return `${seconds} 秒`;
}

function taskLabel(state) {
  return TASK_LABELS[state] || state || '不可用';
}

function hexResult(value) {
  if (value === null || value === undefined) {
    return '—';
  }
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return String(value);
  }
  return `0x${(number >>> 0).toString(16)}`;
}

function recordHistory(exits) {
  const now = Date.now();
  const seen = new Set();
  for (const exit of exits) {
    if (!exit.nodeHash) {
      continue;
    }
    seen.add(exit.nodeHash);
    const latency = Number(exit.latencyMs);
    if (!Number.isFinite(latency) || latency <= 0) {
      continue;
    }
    const points = ui.history.get(exit.nodeHash) || [];
    points.push({ at: now, ms: Math.round(latency) });
    while (points.length > MAX_HISTORY) {
      points.shift();
    }
    ui.history.set(exit.nodeHash, points);
  }
  for (const key of Array.from(ui.history.keys())) {
    if (!seen.has(key)) {
      ui.history.delete(key);
    }
  }
}

function sparkline(points, tone) {
  const width = 82;
  const height = 26;
  const pad = 3;
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', `spark ${tone === 'ok' ? 'ok' : tone === 'warn' ? 'warn' : ''}`.trim());
  svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', points.length ? `最近 ${points.length} 次延迟` : '暂无延迟数据');

  const values = points.map((point) => point.ms);
  if (values.length === 0) {
    const line = document.createElementNS(SVG_NS, 'line');
    line.setAttribute('class', 'spark-line');
    line.setAttribute('x1', String(pad));
    line.setAttribute('y1', String(height / 2));
    line.setAttribute('x2', String(width - pad));
    line.setAttribute('y2', String(height / 2));
    line.setAttribute('stroke-dasharray', '3 3');
    svg.appendChild(line);
    return svg;
  }

  if (values.length === 1) {
    values.push(values[0]);
  }
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = Math.max(1, max - min);
  const step = (width - pad * 2) / Math.max(1, values.length - 1);
  const plotted = values.map((value, index) => {
    const x = pad + step * index;
    const y = pad + (1 - (value - min) / range) * (height - pad * 2);
    return [x, y];
  });

  const line = document.createElementNS(SVG_NS, 'polyline');
  line.setAttribute('class', 'spark-line');
  line.setAttribute('points', plotted.map((point) => `${point[0].toFixed(1)},${point[1].toFixed(1)}`).join(' '));
  svg.appendChild(line);

  const last = plotted[plotted.length - 1];
  const dot = document.createElementNS(SVG_NS, 'circle');
  dot.setAttribute('class', 'spark-dot');
  dot.setAttribute('cx', last[0].toFixed(1));
  dot.setAttribute('cy', last[1].toFixed(1));
  dot.setAttribute('r', '1.9');
  svg.appendChild(dot);

  return svg;
}

function statusLine(tone, label) {
  const wrapper = make('span', `status ${tone}`);
  wrapper.appendChild(make('span', 'status-dot'));
  wrapper.appendChild(document.createTextNode(label));
  return wrapper;
}

function cellSub(text) {
  return make('div', 'cell-sub', text);
}

function copyButton(text, label) {
  const button = make('button', 'copy-btn');
  button.type = 'button';
  button.title = label || '复制';
  button.setAttribute('aria-label', label || '复制');
  button.appendChild(makeIcon('copy'));
  button.addEventListener('click', () => {
    copyText(text, '已复制');
  });
  return button;
}

function csvCell(value) {
  let text = value === undefined || value === null ? '' : String(value);
  if (/^[=+\-@\t\r]/.test(text)) {
    text = `'${text}`;
  }
  return `"${text.replace(/"/g, '""')}"`;
}

function fileTimestamp(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    '-',
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds())
  ].join('');
}

async function exportExitIps(format = 'csv') {
  if (ui.exportBusy) {
    return;
  }

  const direct = format === 'direct';
  const button = byId(direct ? 'export-direct-btn' : 'export-ips-btn');
  const label = byId(direct ? 'export-direct-label' : 'export-ips-label');
  ui.exportBusy = true;
  byId('export-ips-btn').disabled = true;
  byId('export-direct-btn').disabled = true;
  button.setAttribute('aria-busy', 'true');
  label.textContent = '导出中';

  try {
    const response = await fetch('/api/exit-ip-export', {
      cache: 'no-store',
      headers: {
        'X-Exit-Control': '1'
      }
    });
    let result = null;
    try {
      result = await response.json();
    } catch (error) {
      result = null;
    }
    if (!response.ok) {
      throw new Error(result && result.error === 'broker-status-missing'
        ? 'Broker 尚未发布出口状态'
        : `导出失败（HTTP ${response.status}）`);
    }

    const rows = result && Array.isArray(result.exits) ? result.exits : [];
    if (!rows.length) {
      throw new Error('没有可导出的出口节点');
    }

    const header = ['节点', '地区', '协议', 'VPNCheap 服务器 IP/地址', '服务器端口'];
    const lines = rows.map((exit) => [
      exit.nodeName || '',
      exit.country || '',
      exit.protocol || '',
      exit.serverAddress || '',
      exit.serverPort || ''
    ].map(csvCell).join(','));
    const csv = `\uFEFF${header.map(csvCell).join(',')}\r\n${lines.join('\r\n')}\r\n`;
    const addresses = rows.map((exit) => String(exit.serverAddress || '').trim())
      .filter((address) => /^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(address)
        && address.split('.').every((part) => Number(part) <= 255));
    if (direct && !addresses.length) {
      throw new Error('没有可导出的 IPv4 服务器地址');
    }
    const content = direct
      ? `${addresses.map((address) => `- IP-CIDR,${address},DIRECT`).join('\r\n')}\r\n`
      : csv;
    const blob = new Blob([content], { type: direct ? 'text/plain;charset=utf-8' : 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = direct
      ? `vpncheap-direct-rules-${fileTimestamp(new Date())}.txt`
      : `vpncheap-exit-ips-${fileTimestamp(new Date())}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 0);

    const missing = rows.filter((exit) => !exit.serverAddress || !exit.serverPort).length;
    if (direct) {
      const skipped = rows.length - addresses.length;
      showToast(`已导出 ${addresses.length} 条 DIRECT 规则${skipped ? `，跳过 ${skipped} 个缺失或非 IPv4 地址` : ''}`);
    } else {
      showToast(`已导出 ${rows.length} 个节点的服务器地址${missing ? `，${missing} 个地址缺失` : ''}`);
    }
  } catch (error) {
    showToast(error && error.message ? error.message : '导出失败');
  } finally {
    ui.exportBusy = false;
    byId('export-ips-btn').disabled = false;
    byId('export-direct-btn').disabled = false;
    button.removeAttribute('aria-busy');
    label.textContent = direct ? '导出 DIRECT 规则' : '导出服务器';
  }
}

function poolPlanByPort() {
  const plan = (ui.data && Array.isArray(ui.data.poolPlan)) ? ui.data.poolPlan : [];
  const map = new Map();
  plan.forEach((item) => {
    const port = Number(item.port);
    if (Number.isFinite(port) && port > 0) {
      map.set(port, item);
    }
  });
  return map;
}

function creatablePorts() {
  return Array.from(poolPlanByPort().values())
    .filter((item) => item.action === 'create')
    .map((item) => Number(item.port));
}

const POOL_ERROR_LABELS = {
  'invalid-json': '请求格式错误',
  'invalid-port': '端口无效',
  'no-ports': '没有要创建的端口',
  'broker-status-missing': 'Broker 尚未发布状态',
  'broker-not-running': 'Broker 未运行',
  'nine-router-unavailable': '9Router 接口不可用',
  'exit-not-healthy': '出口不健康，无法创建',
  'pool-conflict': '与现有代理池冲突'
};

async function createPools(ports) {
  const list = Array.from(new Set(ports.map(Number).filter((port) => port > 0)));
  if (!list.length || ui.poolBusy) {
    return;
  }
  ui.poolBusy = true;
  ui.poolPending = new Set(list);
  render();
  try {
    const response = await fetch('/api/nine-router/pools', {
      method: 'POST',
      cache: 'no-store',
      headers: {
        'Content-Type': 'application/json',
        'X-Exit-Control': '1'
      },
      body: JSON.stringify({ ports: list })
    });
    let result = null;
    try {
      result = await response.json();
    } catch (error) {
      result = null;
    }
    if (!response.ok) {
      const label = (result && POOL_ERROR_LABELS[result.error]) || `HTTP ${response.status}`;
      throw new Error(result && result.port ? `${label}（端口 ${result.port}）` : label);
    }
    showToast(result && result.ok ? '代理池已对应，测试通过' : '代理池处理未完成，请查看同步结果并重试');
  } catch (error) {
    showToast(error && error.message ? error.message : '创建失败');
  } finally {
    ui.poolBusy = false;
    ui.poolPending = new Set();
    await refresh();
  }
}

async function syncPools() {
  const button = byId('pool-sync');
  button.disabled = true;
  try {
    const response = await fetch('/api/nine-router/sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Exit-Control': '1' },
      body: '{}'
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const accepted = await response.json();
    showToast('代理池同步已开始');
    for (let attempt = 0; attempt < 180; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 2000));
      const stateResponse = await fetch('/api/nine-router/sync', { cache: 'no-store' });
      if (!stateResponse.ok) throw new Error(`HTTP ${stateResponse.status}`);
      const state = await stateResponse.json();
      if (Date.parse(state.updatedAt) < Date.parse(accepted.startedAt)) continue;
      if (state.state === 'running' || state.state === 'pending') continue;
      if (state.state !== 'completed') throw new Error('同步失败，已保留未安全迁移的代理池');
      const removed = (state.actions || []).filter((item) => item.action === 'deleted').length;
      const retained = (state.actions || []).filter((item) => item.action === 'retained').length;
      showToast(`同步完成，清理 ${removed} 个旧代理池${retained ? `，${retained} 个仍有绑定，暂时保留` : ''}`);
      await refresh();
      return;
    }
    showToast('同步仍在后台进行');
  } catch (error) {
    showToast(error.message || '同步失败');
  } finally {
    button.disabled = false;
  }
}

function poolCreateButton(port) {
  const pending = ui.poolPending && ui.poolPending.has(port);
  const button = make('button', 'mini-btn', pending ? '创建中' : '创建代理池');
  button.type = 'button';
  button.disabled = Boolean(ui.poolBusy);
  button.title = `在 9Router 创建 http://127.0.0.1:${port} 代理池`;
  button.addEventListener('click', () => createPools([port]));
  return button;
}

function currentPool(exit) {
  return ((ui.data && ui.data.pools) || []).find(pool => exit.poolId && pool.id === exit.poolId);
}

function poolBindings(pool) {
  return ((ui.data && ui.data.connections) || []).filter(connection => pool && connection.poolId === pool.id);
}

function buildPoolCell(exit, pool) {
  const cell = make('td', 'cell-pool');
  cell.dataset.label = '代理池与同步';
  const ready = exitTone(exit) === 'ok';
  const unavailable = ((ui.data && ui.data.warnings) || []).includes('nine-router-unavailable');
  const plan = poolPlanByPort().get(Number(exit.port));
  if (unavailable) {
    cell.appendChild(statusLine('warn', '无法核对代理池'));
    cell.appendChild(cellSub('9Router 接口不可用，恢复后重新核对'));
    return cell;
  }
  if (exit.poolState === 'conflict' || (pool && pool.relationState === 'conflict') || (plan && plan.action === 'conflict')) {
    cell.appendChild(statusLine('bad', '对应冲突，待核对'));
    cell.appendChild(cellSub('池归属或地址不一致，无法自动同步'));
    if (pool) cell.appendChild(cellSub(pool.name));
    return cell;
  }
  if (pool && exit.poolState === 'matched') {
    cell.appendChild(statusLine(ready && pool.isActive && pool.testStatus === 'active' ? 'ok' : 'warn', '入口已同步'));
    cell.appendChild(make('div', 'pool-name', pool.name || '未命名代理池'));
    const tested = pool.testStatus === 'active' ? '池检测通过' : pool.testStatus === 'error' ? '池检测失败' : '池尚未通过检测';
    cell.appendChild(cellSub(`${tested} · ${pool.lastTestedAt ? formatClock(pool.lastTestedAt) : '检测时间未记录'}`));
    if (!pool.isActive) cell.appendChild(badge('代理池已停用', 'warn'));
    if (!ready) cell.appendChild(make('div', 'relation-note', '入口已对应；线路未就绪，重复同步无法修复线路'));
    return cell;
  }
  cell.appendChild(statusLine('warn', ready ? '待创建代理池' : '未建池，等待线路恢复'));
  cell.appendChild(make('div', 'relation-note', ready
    ? '当前入口尚无对应池，后台将自动同步'
    : '当前入口尚无对应池；线路恢复后自动创建'));
  if (plan && plan.action === 'create') cell.appendChild(poolCreateButton(Number(exit.port)));
  return cell;
}

function buildExitRow(exit) {
  const tone = exitTone(exit);
  const row = make('tr');
  row.dataset.tone = tone;
  const pool = currentPool(exit);

  const nodeCell = make('td', 'cell-node');
  nodeCell.dataset.label = '出口与本地入口';
  nodeCell.appendChild(make('div', 'node-name', exit.configuredNodeName || exit.activeNodeName || exit.nodeName || '待确认节点'));
  if (!exit.configuredNodeName) nodeCell.appendChild(cellSub('配置：原配置待核对'));
  nodeCell.appendChild(make('div', 'node-hash', exit.nodeHash || '—'));
  nodeCell.appendChild(cellSub(`实际：${exit.activeNodeName || '待确认'}${exit.fallbackActive ? ' · 备用' : ''}`));
  if (exit.needsReview) nodeCell.appendChild(cellSub('原配置身份待核对；池对应关系单独核验'));
  row.appendChild(nodeCell);

  const endpoint = exit.endpoint || (exit.port ? `127.0.0.1:${exit.port}` : '—');
  nodeCell.appendChild(chip(endpoint, null, 'mono exit-endpoint'));

  const regionCell = make('div');
  const region = make('div', 'region');
  region.appendChild(make('span', 'region-code', exit.country || '—'));
  region.appendChild(make('span', 'region-protocol', exit.protocol || '未知协议'));
  regionCell.appendChild(region);
  if (exit.fallbackActive) {
    regionCell.appendChild(cellSub(`备用 · ${exit.activeNodeName || exit.activeNodeHash || ''}`));
  }
  if (exit.serverAddress && exit.serverPort) {
    regionCell.appendChild(cellSub(`${exit.serverAddress}:${exit.serverPort}`));
  }

  const statusCell = make('td', 'cell-health');
  statusCell.dataset.label = '线路状态';
  statusCell.appendChild(statusLine(tone, tone === 'ok' ? '线路可用' : `线路${exitStateLabel(exit)}`));
  if (exit.recoveryState) {
    const recoveryLabels = {
      scheduled: '等待恢复验证',
      validating: '正在验证恢复',
      'update-pending': '等待恢复锁',
      'validation-failed': '恢复验证未通过',
      'rolled-back': '恢复未通过，已回退',
      'rollback-failed': '回退失败，等待重建',
      updated: '已重建，等待复检'
    };
    statusCell.appendChild(cellSub(recoveryLabels[exit.recoveryState] || '等待恢复'));
    if (exit.nextRecoveryAt) {
      statusCell.appendChild(cellSub(`下次验证 ${formatClock(exit.nextRecoveryAt)}`));
    }
  }
  if (!exit.processAlive) {
    statusCell.appendChild(cellSub('进程未运行'));
  } else if (exit.consecutiveFailures > 0) {
    statusCell.appendChild(cellSub(`连续失败 ${exit.consecutiveFailures} 次`));
  } else {
    statusCell.appendChild(cellSub(`pwsh.exe · ${PROCESS_LABELS[exit.processState] || exit.processState || '运行中'}`));
  }
  row.appendChild(statusCell);

  const httpCell = make('div');
  const httpStatus = String(exit.httpStatus || '');
  const httpTone = httpStatus === '204' ? 'accent' : httpStatus ? 'warn' : null;
  httpCell.appendChild(chip(httpStatus || '—', httpTone, 'mono'));
  httpCell.prepend(make('span', 'detail-label', 'HTTP 检测 '));

  const latencyBox = make('div', 'latency');
  const history = ui.history.get(exit.nodeHash) || [];
  latencyBox.appendChild(sparkline(history, tone));
  const latency = Number(exit.latencyMs);
  latencyBox.appendChild(make('span', 'latency-value', Number.isFinite(latency) && latency > 0 ? `${Math.round(latency)} ms` : '—'));
  statusCell.appendChild(latencyBox);
  statusCell.appendChild(cellSub(`线路检查 ${formatClock(exit.lastCheckAt)}`));
  row.appendChild(buildPoolCell(exit, pool));

  const bindingCell = make('td', 'cell-bindings');
  bindingCell.dataset.label = '绑定账号';
  const bound = poolBindings(pool);
  bound.forEach(connection => {
    const binding = make('div', 'exit-binding');
    binding.appendChild(make('span', 'provider-name', providerLabel(connection.provider)));
    binding.appendChild(badge(connection.isActive ? '启用' : '停用', connection.isActive ? 'ok' : null));
    bindingCell.appendChild(binding);
  });
  if (!bound.length) bindingCell.appendChild(cellSub(pool && Number(pool.boundConnectionCount) > 0
    ? `${pool.boundConnectionCount} 个绑定，账号信息待核对`
    : ((ui.data && ui.data.warnings) || []).includes('nine-router-unavailable') ? '绑定信息待核对' : '未绑定账号'));
  if (bound.length) bindingCell.appendChild(cellSub('含停用账号，取消出口前需先解除绑定'));
  row.appendChild(bindingCell);

  const hashCell = make('div');
  hashCell.appendChild(make('div', 'detail-label', '出口 IP 哈希'));
  hashCell.appendChild(buildHashCell(exit.exitIpHash));
  if (exit.healthOk && exit.exitIpOk === false) {
    hashCell.appendChild(cellSub('IP 查询暂不可用'));
  }

  const workerCell = make('div');
  workerCell.appendChild(make('div', 'detail-label', 'Worker'));
  workerCell.appendChild(make('div', 'pid', exit.workerPid ? `PID ${exit.workerPid}` : '—'));
  const workerMeta = [];
  if (exit.singBoxVersion) {
    workerMeta.push(exit.singBoxVersion);
  }
  if (exit.restartCount > 0) {
    workerMeta.push(`重启 ${exit.restartCount}`);
  }
  if (workerMeta.length) {
    workerCell.appendChild(cellSub(workerMeta.join(' · ')));
  }
  if (exit.updateState || exit.updateErrorHash) {
    const labels = {
      updating: '更新中',
      validating: '正在验证新配置',
      pending: '等待更新',
      'update-pending': '等待更新锁',
      updated: '已更新',
      error: '更新失败',
      failed: '更新失败',
      unchanged: '配置未变',
      current: '配置最新',
      'needs-review': '待核对映射',
      'catalog-error': '读取订阅失败',
      'snapshot-error': '配置快照保存失败',
      'validation-failed': '更新验证失败',
      'rollback-failed': '回退失败，等待恢复',
      'rolled-back': '已回退'
    };
    const label = labels[exit.updateState] || exit.updateState || '更新失败';
    const feedback = cellSub(`${label}${exit.updateErrorHash ? ` · ${shortId(exit.updateErrorHash)}` : ''}`);
    if (exit.updateErrorHash || ['error', 'failed', 'validation-failed', 'rolled-back', 'rollback-failed', 'catalog-error', 'snapshot-error'].includes(exit.updateState)) {
      feedback.classList.add('update-error');
    }
    feedback.title = exit.updateErrorHash || '';
    workerCell.appendChild(feedback);
  }

  const checkCell = make('div');
  checkCell.appendChild(make('div', 'detail-label', '最近线路检查'));
  checkCell.appendChild(make('div', 'pid', formatClock(exit.lastCheckAt)));
  const relative = formatRelative(exit.lastCheckAt);
  if (relative) {
    checkCell.appendChild(cellSub(relative));
  }
  const detailCell = make('td', 'cell-details');
  detailCell.dataset.label = '运行详情';
  const details = make('details', 'exit-details');
  details.open = ui.expandedExits.has(exit.nodeHash);
  details.addEventListener('toggle', () => {
    if (!details.isConnected) return;
    if (details.open) ui.expandedExits.add(exit.nodeHash);
    else ui.expandedExits.delete(exit.nodeHash);
  });
  details.appendChild(make('summary', null, '查看详情'));
  details.append(regionCell, httpCell, hashCell, workerCell, checkCell);
  detailCell.appendChild(details);
  row.appendChild(detailCell);

  return row;
}

function buildHashCell(hash) {
  const wrapper = make('div', 'hash-cell');
  if (!hash) {
    wrapper.appendChild(make('span', 'hash-value', '—'));
    return wrapper;
  }
  const value = make('span', 'hash-value', hash.slice(0, 12));
  value.title = hash;
  wrapper.appendChild(value);
  wrapper.appendChild(copyButton(hash, '复制完整出口 IP 哈希'));
  return wrapper;
}

function exitMatches(exit) {
  if (ui.filter === 'healthy' && exitTone(exit) !== 'ok') {
    return false;
  }
  if (ui.filter === 'bad' && exitTone(exit) === 'ok') {
    return false;
  }
  const query = ui.query.trim().toLowerCase();
  if (!query) {
    return true;
  }
  const haystack = [
    exit.nodeName,
    exit.configuredNodeName,
    exit.activeNodeName,
    exit.poolName,
    ...poolBindings(currentPool(exit)).map(connection => providerLabel(connection.provider)),
    exit.nodeHash,
    exit.country,
    exit.protocol,
    exit.port,
    exit.exitIpHash
  ].join(' ').toLowerCase();
  return haystack.includes(query);
}

function renderExits() {
  const exits = (ui.data && Array.isArray(ui.data.exits)) ? ui.data.exits : [];
  const healthy = exits.filter((exit) => exitTone(exit) === 'ok').length;
  const bad = exits.length - healthy;

  setText('count-all', String(exits.length));
  setText('count-healthy', String(healthy));
  setText('count-bad', String(bad));
  setText('exit-subtitle', exits.length
    ? `${exits.length} 个当前出口 · ${healthy} 条线路可用 · ${exits.filter(exit => exit.poolState === 'matched').length} 个代理池已同步`
    : '本地回环入口 · 暂无出口');

  const visible = exits.filter(exitMatches);
  const body = byId('exit-body');
  body.replaceChildren(...visible.map((exit) => buildExitRow(exit)));

  const empty = byId('exit-empty');
  const emptyText = byId('exit-empty-text');
  if (visible.length === 0) {
    empty.hidden = false;
    if (ui.loading && !ui.data) {
      emptyText.textContent = '正在读取运行状态';
    } else if (ui.error && !ui.data) {
      emptyText.textContent = '无法连接本地服务';
    } else if (exits.length === 0) {
      emptyText.textContent = 'Broker 尚未发布出口';
    } else {
      emptyText.textContent = '没有匹配的出口节点';
    }
  } else {
    empty.hidden = true;
  }
}

function candidateNodes() {
  return (ui.data && Array.isArray(ui.data.candidates)) ? ui.data.candidates : [];
}

function clampExitCount(value) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed)) {
    return 1;
  }
  return Math.min(64, Math.max(1, parsed));
}

function setConfigError(message) {
  const error = byId('config-error');
  error.hidden = !message;
  error.textContent = message || '';
}

function renderCandidateList() {
  const candidates = candidateNodes();
  const config = ui.config;
  const query = config.query.trim().toLowerCase();
  const list = byId('candidate-list');
  const filtered = candidates.filter((candidate) => {
    if (!query) {
      return true;
    }
    return [candidate.nodeName, candidate.country, candidate.protocol, candidate.nodeHash]
      .some((value) => String(value || '').toLowerCase().includes(query));
  }).sort((left, right) => Number(right.category === 'existing' || right.selected) - Number(left.category === 'existing' || left.selected));

  setText('candidate-summary', `${filtered.length} / ${candidates.length} · 已选 ${config.selected.size}`);
  setText('config-subtitle', `当前 ${config.maxExits} 个并行出口 · 候选 ${candidates.length} 个`);

  if (!filtered.length) {
    const empty = make('div', 'candidate-empty', candidates.length ? '没有匹配的候选节点' : '候选节点尚未发布');
    list.replaceChildren(empty);
    return;
  }

  const fragment = document.createDocumentFragment();
  let group = '';
  filtered.forEach((candidate) => {
    const nextGroup = candidate.category === 'existing' || candidate.selected ? '已有出口' : '可新增节点';
    if (group !== nextGroup) {
      fragment.appendChild(make('div', 'candidate-group', nextGroup));
      group = nextGroup;
    }
    const hash = String(candidate.nodeHash || '');
    const checked = config.selected.has(hash);
    const atLimit = !checked && config.selected.size >= config.maxExits;
    const reason = candidate.disabledReason === 'node-occupied'
      ? `已被出口 ${(candidate.occupiedBy || []).map(value => shortId(value)).join('、')} 占用`
      : candidate.disabledReason === 'mapping-review' ? '待核对映射'
      : config.auto ? '自动选择' : atLimit ? '数量已满' : '';
    const disabled = config.auto || (Boolean(reason) && !checked);
    const row = make('label', 'candidate-row');
    row.classList.toggle('is-selected', checked);
    row.classList.toggle('is-disabled', disabled && !checked);

    const input = make('input');
    input.type = 'checkbox';
    input.checked = checked;
    input.disabled = disabled;
    input.setAttribute('aria-label', `${candidate.nodeName || '节点'} ${shortId(hash)}`);
    input.addEventListener('change', () => {
      if (input.checked) {
        config.selected.add(hash);
      } else {
        config.selected.delete(hash);
      }
      setConfigError('');
      renderCandidateList();
    });

    const name = make('span', 'candidate-name', candidate.nodeName || shortId(hash, 12));
    const metaText = [candidate.country, candidate.protocol, shortId(hash), reason || (candidate.needsReview ? '待核对映射' : '')].filter(Boolean).join(' · ');
    const meta = make('span', 'candidate-meta', metaText || shortId(hash, 12));
    row.append(input, name, meta);
    fragment.appendChild(row);
  });
  list.replaceChildren(fragment);
}

function openConfigDialog() {
  const broker = (ui.data && ui.data.broker) || {};
  const candidates = candidateNodes();
  const selected = new Set(
    candidates.filter((candidate) => candidate.selected).map((candidate) => String(candidate.nodeHash || ''))
  );
  const configured = Number(broker.configuredMaxExits);
  const effective = Number(broker.maxExits);
  ui.config.maxExits = clampExitCount(configured || effective || selected.size || 1);
  ui.config.auto = broker.selectionMode !== 'manual';
  ui.config.selected = selected;
  ui.config.query = '';
  ui.config.saving = false;

  byId('exit-count').value = String(ui.config.maxExits);
  byId('auto-select').checked = ui.config.auto;
  byId('candidate-search').value = '';
  byId('config-save').disabled = false;
  byId('config-save').textContent = '应用';
  setConfigError('');
  renderCandidateList();

  const dialog = byId('exit-config-dialog');
  if (typeof dialog.showModal === 'function') {
    dialog.showModal();
  } else {
    dialog.setAttribute('open', '');
  }
}

function closeConfigDialog() {
  const dialog = byId('exit-config-dialog');
  if (typeof dialog.close === 'function') {
    dialog.close();
  } else {
    dialog.removeAttribute('open');
  }
}

async function applyExitConfig(event) {
  event.preventDefault();
  const config = ui.config;
  config.maxExits = clampExitCount(byId('exit-count').value);
  byId('exit-count').value = String(config.maxExits);

  if (!config.auto && config.selected.size === 0) {
    setConfigError('手动模式下至少选择一个节点');
    return;
  }
  if (!config.auto && config.selected.size > config.maxExits) {
    setConfigError('选择数量超过并行出口数');
    return;
  }

  const payload = {
    maxExits: config.maxExits,
    nodeHashes: config.auto ? [] : Array.from(config.selected)
  };
  const save = byId('config-save');
  config.saving = true;
  save.disabled = true;
  save.textContent = '应用中';
  setConfigError('');

  try {
    const response = await fetch('/api/exit-config', {
      method: 'POST',
      cache: 'no-store',
      headers: {
        'Content-Type': 'application/json',
        'X-Exit-Control': '1'
      },
      body: JSON.stringify(payload)
    });
    let result = null;
    try {
      result = await response.json();
    } catch (error) {
      result = null;
    }
    if (!response.ok) {
      const labels = {
        'candidate-list-unavailable': 'Broker 尚未发布候选节点',
        'selection-exceeds-max': '选择数量超过并行出口数',
        'unknown-node': '候选节点已变化，请重新打开',
        'invalid-max-exits': '出口数量无效'
        , 'node-unavailable': '节点已被占用或映射待核对，请刷新后选择'
        , 'exit-has-bindings': '出口仍有连接绑定，请先迁移或解除绑定'
        , 'binding-check-unavailable': '无法核验绑定，保留现有出口，请稍后重试'
        , 'broker-status-not-safe': 'Broker 状态不可用或已过期'
        , 'config-change-running': '其他配置正在保存，请稍后重试'
      };
      const affected = result && Array.isArray(result.affected) ? result.affected.map(item => `${providerLabel(item.provider)} (${item.port})`).join('、') : '';
      throw new Error(((result && labels[result.error]) || `HTTP ${response.status}`) + (affected ? `：${affected}` : ''));
    }
    closeConfigDialog();
    showToast('配置已保存，等待出口调整与代理池同步');
    window.setTimeout(() => refresh(), 1200);
  } catch (error) {
    setConfigError(error && error.message ? error.message : '应用失败');
  } finally {
    config.saving = false;
    save.disabled = false;
    save.textContent = '应用';
  }
}

function renderStats() {
  const data = ui.data;
  if (!data) {
    ['stat-healthy', 'stat-latency', 'stat-pools', 'stat-candidates', 'stat-uptime'].forEach((id) => setText(id, '—'));
    setText('stat-healthy-meta', ui.error ? '服务不可达' : '读取中');
    setText('stat-latency-meta', '近期检查');
    setText('stat-pools-meta', '当前出口对应');
    setText('stat-candidates-meta', '节点目录');
    setText('stat-uptime-meta', 'Broker');
    return;
  }

  const broker = data.broker || {};
  const exits = Array.isArray(data.exits) ? data.exits : [];
  const selected = Number(broker.selectedCount) || 0;
  const healthy = Number(broker.healthyCount) || 0;

  setText('stat-healthy', `${healthy}/${selected}`);
  if (broker.state === 'running') {
    setText('stat-healthy-meta', healthy === selected ? '全部出口在线' : `${Math.max(0, selected - healthy)} 个出口异常`);
  } else {
    setText('stat-healthy-meta', 'Broker 未运行');
  }

  const latencies = exits
    .filter((exit) => exit.healthOk)
    .map((exit) => Number(exit.latencyMs))
    .filter((value) => Number.isFinite(value) && value > 0);
  if (latencies.length) {
    const average = Math.round(latencies.reduce((sum, value) => sum + value, 0) / latencies.length);
    setText('stat-latency', `${average} ms`);
    setText('stat-latency-meta', `${latencies.length} 个健康出口`);
  } else {
    setText('stat-latency', '—');
    setText('stat-latency-meta', '暂无健康样本');
  }

  const pools = Array.isArray(data.pools) ? data.pools : [];
  const matched = pools.filter(pool => pool.relationState === 'matched').length;
  const unavailable = (data.warnings || []).includes('nine-router-unavailable');
  setText('stat-pools', unavailable ? '待核对' : `${matched}/${exits.length}`);
  setText('stat-pools-meta', unavailable ? '9Router 接口不可用' : `另有 ${pools.length - matched} 个历史或其他池`);

  setText('stat-candidates', String(Number(broker.candidateCount) || 0));
  const scope = [
    broker.protocol || '全部协议',
    broker.country || '全部地区',
    broker.selectionMode === 'manual' ? '手动选取' : '自动选取'
  ];
  setText('stat-candidates-meta', scope.join(' · '));

  setText('stat-uptime', broker.state === 'running' ? formatUptime(broker.startedAt) : '—');
  setText('stat-uptime-meta', broker.pid ? `Broker PID ${broker.pid}` : 'Broker');
}

function renderWarnings() {
  const reasons = {
    'exit-has-bindings': '出口仍有绑定，请先迁移或解除绑定',
    'binding-check-unavailable': '无法核验最新绑定，保留现有出口',
    'config-selection-changed': '配置已变化，请重新核对',
    'node-unavailable': '节点已被占用或映射待核对',
    'unknown-node': '候选节点已变化，请重新选择',
    'owned-address-edited': '托管池地址被修改，请核对',
    'ambiguous-ownership': '存在多个归属记录，请核对',
    'duplicate-port': '多个代理池使用同一入口',
    'port-not-owned': '入口已被其他代理池占用',
    'name-not-owned': '预期池名已被外部对象占用',
    'create-outcome-unknown': '创建结果不确定，请核对远端池与台账',
    'create-failed': '代理池创建失败',
    'test-failed': '代理池测试未通过',
    'replacement-test-failed': '迁移目标测试未通过，保留原池',
    'replacement-unavailable': '迁移目标不可用，保留原池'
  };
  const progress = byId('configuration-progress');
  const configuration = ui.data && ui.data.configuration;
  if (progress) {
    const labels = { saved: '配置已保存', adjusting: '配置已保存，出口调整中', 'exit-error': '出口调整未完成',
      syncing: '出口已生效，代理池同步中', 'sync-error': '出口已生效，代理池同步失败', completed: '出口与代理池已完成对应' };
    progress.hidden = !configuration || !labels[configuration.state];
    if (!progress.hidden) {
      progress.replaceChildren(make('span', null, labels[configuration.state]));
      if (configuration.reason) progress.appendChild(cellSub(reasons[configuration.reason] || configuration.reason));
      if (configuration.state === 'exit-error' && ui.data.exits) {
        ui.data.exits.filter(exit => !exit.healthOk).forEach(exit =>
          progress.appendChild(cellSub(`${exit.endpoint || exit.nodeHash} · ${exitStateLabel(exit)}`)));
      }
      const failures = configuration.sync && Array.isArray(configuration.sync.actions) ? configuration.sync.actions
        .filter(item => ['conflict', 'create-failed', 'test-failed'].includes(item.action) || /failed|unavailable/.test(item.reason || '')) : [];
      failures.forEach(item => progress.appendChild(cellSub(`${item.port || shortId(item.poolId || item.nodeHash)} · ${reasons[item.reason || item.action] || item.reason || item.action}`)));
      if (configuration.state === 'sync-error') {
        const retry = make('button', 'link-btn configuration-retry', '重试代理池同步');
        retry.type = 'button';
        retry.addEventListener('click', syncPools);
        progress.appendChild(retry);
      }
    }
  }
  const labels = new Set();
  if (ui.data && Array.isArray(ui.data.warnings)) {
    ui.data.warnings.forEach((warning) => labels.add(WARNING_LABELS[warning] || warning));
  }
  if (ui.error) {
    labels.add(WARNING_LABELS['api-offline']);
  }

  const band = byId('warning-band');
  const chips = byId('warning-chips');
  if (labels.size === 0) {
    band.hidden = true;
    chips.replaceChildren();
    return;
  }

  band.hidden = false;
  chips.replaceChildren(...Array.from(labels).map((label) => make('span', 'warning-chip', label)));
}

function renderTopbar() {
  const pill = byId('broker-pill');
  const data = ui.data;
  let tone = 'idle';
  let label = '连接中';

  if (ui.error) {
    tone = 'bad';
    label = '连接中断';
  } else if (!data) {
    tone = 'idle';
    label = ui.loading ? '连接中' : '无数据';
  } else {
    const broker = data.broker || {};
    const selected = Number(broker.selectedCount) || 0;
    const healthy = Number(broker.healthyCount) || 0;
    if (broker.state !== 'running') {
      tone = 'bad';
      label = 'Broker 已停止';
    } else if (healthy < selected) {
      tone = 'warn';
      label = '部分降级';
    } else {
      tone = 'ok';
      label = '运行正常';
    }
  }

  pill.className = `broker-pill is-${tone}`;
  setText('broker-pill-text', label);

  if (ui.fetchedAt) {
    const stamp = clockFormat.format(new Date(ui.fetchedAt));
    setText('updated-at', ui.error ? `更新中断 · 停在 ${stamp}` : `更新于 ${stamp}`);
  } else {
    setText('updated-at', ui.error ? '更新中断' : '等待数据');
  }
}

function renderPools() {
  const data = ui.data;
  const currentIds = new Set(((data && data.exits) || []).map(exit => exit.poolId).filter(Boolean));
  const pools = ((data && data.pools) || []).filter(pool => !currentIds.has(pool.id));
  const connections = (data && Array.isArray(data.connections)) ? data.connections : [];
  const list = byId('pool-list');
  const empty = byId('pool-empty');

  if (!data) {
    setText('pool-subtitle', ui.error ? '服务不可达' : '读取中');
    list.replaceChildren();
    setText('pool-empty-text', ui.error ? '无法读取代理池' : '正在读取代理池');
    empty.hidden = false;
    return;
  }

  const createAll = byId('pool-create-all');
  const creatable = creatablePorts();
  createAll.hidden = creatable.length === 0 && !ui.poolBusy;
  createAll.disabled = Boolean(ui.poolBusy);
  setText('pool-create-all-label', ui.poolBusy ? '创建中' : `为 ${creatable.length} 个出口创建`);

  const historical = pools.filter(pool => pool.relationState === 'historical').length;
  const external = pools.filter(pool => pool.relationState === 'external').length;
  const review = pools.length - historical - external;
  setText('pool-subtitle', `${historical} 个历史保留 · ${external} 个外部管理 · ${review} 个待核对`);
  const unavailable = (data.warnings || []).includes('nine-router-unavailable');
  setText('pool-empty-text', unavailable ? '9Router 接口不可用，暂时无法核对' : '暂无历史或其他代理池；当前对应池见上表');

  pools.sort((left, right) => {
    if (Boolean(left.managed) !== Boolean(right.managed)) {
      return left.managed ? -1 : 1;
    }
    const leftPort = Number(left.port) || 0;
    const rightPort = Number(right.port) || 0;
    if (leftPort !== rightPort) {
      return leftPort - rightPort;
    }
    return String(left.name || '').localeCompare(String(right.name || ''), 'zh-CN');
  });

  list.replaceChildren(...pools.map((pool) => {
    const row = make('div', 'pool-row');
    const main = make('div');
    const title = make('div', 'pool-title');
    title.appendChild(make('strong', null, pool.name || '未命名代理池'));
    title.appendChild(badge(pool.managed ? '本工具托管' : '外部管理', pool.managed ? 'accent' : null));
    main.appendChild(title);

    const bound = connections.filter((connection) => connection.poolId === pool.id);
    let boundText = '未绑定账号';
    if (bound.length) {
      const names = bound.slice(0, 3).map((connection) => providerLabel(connection.provider));
      boundText = `绑定 ${names.join('、')}${bound.length > 3 ? ` 等 ${bound.length} 个` : ''}`;
    } else if (Number(pool.boundConnectionCount) > 0) {
      boundText = `${pool.boundConnectionCount} 个连接绑定`;
    }
    main.appendChild(cellSub(boundText));
    if (pool.nodeHash) main.appendChild(cellSub(`出口 ${shortId(pool.nodeHash)}`));
    if (pool.reason) main.appendChild(cellSub(pool.reason));
    if (pool.relationState === 'historical') main.appendChild(make('div', 'relation-note', '未对应当前出口；保留原绑定，迁移需明确操作'));
    row.appendChild(main);

    const endpoint = make('div', 'endpoint-line');
    const endpointText = pool.endpoint === 'LAN' ? '局域网' : (pool.endpoint || '—');
    endpoint.appendChild(chip(endpointText, pool.port ? null : 'warn', 'mono'));
    endpoint.appendChild(cellSub(`${String(pool.type || 'http').toUpperCase()}${pool.port ? ` · 端口 ${pool.port}` : ' · 非本机'}`));
    row.appendChild(endpoint);

    const badges = make('div', 'badge-row');
    const testTone = pool.testStatus === 'active' ? 'ok' : (pool.testStatus ? 'warn' : null);
    badges.appendChild(badge(pool.testStatus === 'active' ? '上次池检测通过' : pool.testStatus === 'error' ? '上次池检测失败' : '尚未通过检测', testTone));
    if (pool.relationState === 'historical') badges.appendChild(badge('历史保留', 'warn'));
    if (pool.relationState === 'conflict') badges.appendChild(badge('对应冲突', 'bad'));
    if (!['historical', 'external', 'conflict'].includes(pool.relationState)) badges.appendChild(badge('待核对', 'warn'));
    badges.title = `池检测：${pool.lastTestedAt ? formatClock(pool.lastTestedAt) : '时间未记录'}；出口健康单独显示`;
    badges.appendChild(cellSub(`上次池检测 ${pool.lastTestedAt ? formatClock(pool.lastTestedAt) : '时间未记录'}`));
    if (pool.relationState === 'historical') badges.appendChild(cellSub('不代表当前出口可用'));
    if (pool.strictProxy) {
      badges.appendChild(badge('strict', null));
    }
    if (!pool.isActive) {
      badges.appendChild(badge('已停用', 'bad'));
    }
    row.appendChild(badges);
    return row;
  }));

  empty.hidden = pools.length > 0;
}

function renderConnections() {
  const data = ui.data;
  const connections = (data && Array.isArray(data.connections)) ? data.connections.slice() : [];
  const list = byId('connection-list');
  const empty = byId('connection-empty');

  if (!data) {
    setText('connection-subtitle', ui.error ? '服务不可达' : '读取中');
    list.replaceChildren();
    empty.hidden = false;
    return;
  }

  const bound = connections.filter((connection) => connection.poolId);
  setText('connection-subtitle', `${connections.length} 个账号连接 · ${bound.length} 个已绑定 · ${connections.length - bound.length} 个未绑定`);

  connections.sort((left, right) => {
    const leftBound = left.poolId ? 1 : 0;
    const rightBound = right.poolId ? 1 : 0;
    if (leftBound !== rightBound) {
      return rightBound - leftBound;
    }
    const leftPriority = Number(left.priority) || 0;
    const rightPriority = Number(right.priority) || 0;
    if (leftPriority !== rightPriority) {
      return leftPriority - rightPriority;
    }
    return providerLabel(left.provider).localeCompare(providerLabel(right.provider), 'zh-CN');
  });

  list.replaceChildren(...connections.map((connection) => {
    const row = make('div', 'connection-row');

    const main = make('div');
    main.appendChild(make('div', 'provider-name', providerLabel(connection.provider)));
    main.appendChild(make('div', 'provider-sub', connection.id ? `#${shortId(connection.id)}` : '—'));
    row.appendChild(main);

    const poolRef = make('div', `pool-ref${connection.poolId ? '' : ' is-unbound'}`, connection.poolId ? (connection.poolName || '已绑定') : '未绑定');
    if (connection.poolId) {
      poolRef.appendChild(cellSub([connection.endpoint, connection.activeNodeName].filter(Boolean).join(' · ') || '入口或实际节点待核对'));
      const pool = ((data && data.pools) || []).find(item => item.id === connection.poolId);
      poolRef.appendChild(cellSub(pool && pool.relationState === 'historical'
        ? '使用历史池，未迁移到当前出口' : connection.routeState || '关系待核对'));
    }
    row.appendChild(poolRef);

    const meta = make('div', 'conn-meta');
    meta.appendChild(badge(`P${Number(connection.priority) || 1}`, null));
    meta.appendChild(badge(connection.isActive ? '启用' : '停用', connection.isActive ? 'ok' : 'bad'));
    row.appendChild(meta);
    return row;
  }));

  empty.hidden = connections.length > 0;
}

function renderFlow() {
  const data = ui.data;
  const flow = byId('flow');
  const procGrid = byId('proc-grid');
  if (!data) {
    flow.replaceChildren();
    procGrid.replaceChildren();
    return;
  }

  const broker = data.broker || {};
  const task = data.task;
  const exits = Array.isArray(data.exits) ? data.exits : [];
  const versions = Array.from(new Set(exits.map((exit) => exit.singBoxVersion).filter(Boolean)));
  const ports = exits.map((exit) => exit.port).filter((port) => Number(port) > 0).sort((a, b) => a - b);

  const steps = [
    {
      icon: 'clock',
      title: '计划任务',
      meta: task ? taskLabel(task.state) : '不可用',
      sub: 'vpncheap-multi-exit-broker'
    },
    {
      icon: 'terminal',
      title: 'Broker',
      meta: broker.pid ? `pwsh.exe · PID ${broker.pid}` : '未运行',
      sub: broker.instanceId ? `实例 ${shortId(broker.instanceId)}` : 'supervisor'
    },
    {
      icon: 'server',
      title: `Worker × ${exits.length}`,
      meta: exits.length ? `pwsh.exe × ${exits.filter((exit) => exit.processAlive).length}` : '无',
      sub: exits.length
        ? exits.map((exit) => `${exit.port}${exit.workerPid ? ` · ${exit.workerPid}` : ''}`).join(' / ')
        : '独立进程'
    },
    {
      icon: 'cpu',
      title: 'sing-box',
      meta: versions.length ? versions.join(' / ') : '—',
      sub: 'sing-box.dll · 进程内'
    },
    {
      icon: 'network',
      title: '回环入口',
      meta: '127.0.0.1',
      sub: ports.length ? ports.join(' · ') : '—'
    }
  ];

  const children = [];
  steps.forEach((step, index) => {
    if (index > 0) {
      const arrow = make('div', 'flow-arrow');
      arrow.appendChild(makeIcon('chevron'));
      children.push(arrow);
    }
    const node = make('div', 'flow-node');
    const iconBox = make('span', 'flow-icon');
    iconBox.appendChild(makeIcon(step.icon));
    node.appendChild(iconBox);
    const body = make('div', 'flow-body');
    body.appendChild(make('div', 'flow-title', step.title));
    body.appendChild(make('div', 'flow-meta', step.meta));
    body.appendChild(make('div', 'flow-sub', step.sub));
    node.appendChild(body);
    children.push(node);
  });
  flow.replaceChildren(...children);

  const aliveWorkers = exits.filter((exit) => exit.processAlive).length;
  const procCells = [
    {
      label: 'Broker 进程',
      value: broker.state === 'running' && broker.pid ? `PID ${broker.pid}` : '未运行',
      sub: broker.startedAt ? `启动于 ${formatClock(broker.startedAt)}` : '无启动记录'
    },
    {
      label: 'Worker 进程',
      value: `${aliveWorkers}/${exits.length} 运行中`,
      sub: exits.length ? exits.map((exit) => `${exit.port}:${exit.workerPid || '—'}`).join(' · ') : '暂无 Worker'
    },
    {
      label: '计划任务',
      value: task ? taskLabel(task.state) : '不可用',
      sub: task ? `上次结果 ${hexResult(task.lastResult)}` : '未安装或不可读'
    },
    {
      label: '端口范围',
      value: ports.length ? `${ports[0]} – ${ports[ports.length - 1]}` : '—',
      sub: `最大出口 ${Number(broker.maxExits) || 0} · ${broker.protocol || '全部协议'}`
    }
  ];

  procGrid.replaceChildren(...procCells.map((cell) => {
    const wrapper = make('div', 'proc');
    wrapper.appendChild(make('div', 'proc-label', cell.label));
    wrapper.appendChild(make('div', 'proc-value', cell.value));
    wrapper.appendChild(make('div', 'proc-sub', cell.sub));
    return wrapper;
  }));
}

function render() {
  renderTopbar();
  renderSubscription();
  renderWarnings();
  renderStats();
  renderExits();
  renderPools();
  renderConnections();
  renderFlow();
}

function renderSubscription() {
  const subscription = (ui.data && ui.data.subscription) || {};
  const busy = ui.subscriptionPosting || subscription.state === 'refreshing';
  const button = byId('subscription-refresh-btn');
  const status = byId('subscription-status');
  const cooldownUntil = Math.max(ui.subscriptionCooldownUntil, Date.parse(subscription.cooldownUntil) || 0);
  button.disabled = busy || Date.now() < cooldownUntil;
  button.classList.toggle('is-spinning', busy);
  button.setAttribute('aria-busy', String(busy));
  status.classList.toggle('is-busy', busy);
  status.classList.toggle('is-error', !busy && (Boolean(ui.subscriptionError) || subscription.state === 'error'));

  let label = '订阅 · 尚未更新';
  if (busy) {
    label = '订阅 · 更新中';
  } else if (ui.subscriptionError) {
    label = `订阅 · ${ui.subscriptionError}`;
  } else if (subscription.state === 'error') {
    const errors = {
      'subscription-login-required': '请先登录 VPNCheap',
      'subscription-empty-catalog': '未返回可用节点',
      'subscription-network-refresh-failed': '网络更新失败',
      'subscription-invalid-catalog': '节点数据无效',
      'subscription-suspicious-catalog-shrink': '节点数量异常，已保留原订阅',
      'subscription-refresh-incomplete': '更新未完成，请重试'
    };
    label = `订阅 · ${errors[subscription.errorCode] || '更新失败'}`;
    if (subscription.errorHash) {
      label += ` · ${shortId(subscription.errorHash)}`;
    }
    if (subscription.lastSuccessAt) {
      label += ` · 上次成功 ${formatClock(subscription.lastSuccessAt)}`;
    }
  } else if (subscription.state === 'updated' || subscription.lastSuccessAt) {
    label = `订阅 · 已更新 ${formatClock(subscription.lastSuccessAt || subscription.updatedAt)}`;
    if (subscription.nodeCount !== null && subscription.nodeCount !== undefined) {
      label += ` · ${subscription.nodeCount} 个节点`;
    }
  }
  status.textContent = label;
  status.title = [
    subscription.errorCode,
    subscription.errorHash,
    subscription.nextRefreshAt ? `下次更新 ${formatClock(subscription.nextRefreshAt)}` : ''
  ].filter(Boolean).join(' · ');
  armSubscriptionPoll();
}

function armSubscriptionPoll() {
  window.clearTimeout(ui.subscriptionTimer);
  const subscription = (ui.data && ui.data.subscription) || {};
  const cooldownUntil = Math.max(ui.subscriptionCooldownUntil, Date.parse(subscription.cooldownUntil) || 0);
  const watching = ui.subscriptionPosting || subscription.state === 'refreshing' || Date.now() < ui.subscriptionWatchUntil;
  if (!watching && Date.now() >= cooldownUntil) {
    return;
  }
  ui.subscriptionTimer = window.setTimeout(async () => {
    if (watching) {
      await refresh();
    }
    renderSubscription();
  }, watching ? 1500 : Math.max(50, cooldownUntil - Date.now()));
}

async function refreshSubscription() {
  if (byId('subscription-refresh-btn').disabled || ui.subscriptionPosting) {
    return;
  }
  ui.subscriptionPosting = true;
  ui.subscriptionError = '';
  renderSubscription();
  try {
    const response = await fetch('/api/subscription/refresh', {
      method: 'POST',
      cache: 'no-store',
      headers: {
        'Content-Type': 'application/json',
        'X-Exit-Control': '1'
      },
      body: '{}'
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(result.error === 'subscription-refresh-launch-failed' ? '无法启动更新' : `请求失败（HTTP ${response.status}）`);
    }
    ui.subscriptionCooldownUntil = Date.parse(result.subscription && result.subscription.cooldownUntil) || Date.now() + 10000;
    ui.subscriptionWatchUntil = Date.now() + 10000;
    if (ui.data && result.subscription) {
      ui.data.subscription = result.subscription;
    }
  } catch (error) {
    ui.subscriptionError = error && error.message ? error.message : '更新请求失败';
    showToast(ui.subscriptionError);
  } finally {
    ui.subscriptionPosting = false;
    await refresh();
    renderSubscription();
  }
}

async function refresh() {
  if (ui.inflight) {
    return;
  }
  ui.inflight = true;
  byId('refresh-btn').classList.add('is-spinning');
  try {
    const response = await fetch('/api/snapshot', { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const data = await response.json();
    ui.data = data;
    ui.error = null;
    ui.fetchedAt = Date.now();
    recordHistory(Array.isArray(data.exits) ? data.exits : []);
  } catch (error) {
    ui.error = error && error.message ? error.message : 'fetch failed';
  } finally {
    ui.inflight = false;
    ui.loading = false;
    byId('refresh-btn').classList.remove('is-spinning');
    render();
  }
}

function armTimer() {
  window.clearTimeout(ui.timer);
  if (!ui.auto) {
    return;
  }
  ui.timer = window.setTimeout(async () => {
    if (!document.hidden) {
      await refresh();
    }
    armTimer();
  }, REFRESH_MS);
}

function showToast(message) {
  const toast = byId('toast');
  toast.textContent = message;
  toast.classList.add('is-visible');
  window.clearTimeout(ui.toastTimer);
  ui.toastTimer = window.setTimeout(() => {
    toast.classList.remove('is-visible');
  }, 1600);
}

async function copyText(text, message) {
  try {
    await navigator.clipboard.writeText(text);
    showToast(message);
  } catch (error) {
    const helper = byId('clip-helper');
    helper.value = text;
    helper.select();
    try {
      document.execCommand('copy');
      showToast(message);
    } catch (fallbackError) {
      showToast('复制失败');
    }
    helper.value = '';
  }
}

function bind() {
  document.querySelectorAll('.seg-btn').forEach((button) => {
    button.addEventListener('click', () => {
      ui.filter = button.dataset.filter || 'all';
      document.querySelectorAll('.seg-btn').forEach((candidate) => {
        const active = candidate === button;
        candidate.classList.toggle('is-active', active);
        candidate.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
      renderExits();
    });
  });

  const search = byId('exit-search');
  search.addEventListener('input', () => {
    ui.query = search.value;
    renderExits();
  });

  const auto = byId('auto-refresh');
  auto.checked = ui.auto;
  auto.addEventListener('change', () => {
    ui.auto = auto.checked;
    saveAutoPreference(ui.auto);
    armTimer();
    if (ui.auto) {
      refresh();
    }
  });

  byId('refresh-btn').addEventListener('click', () => {
    refresh();
    armTimer();
  });
  byId('subscription-refresh-btn').addEventListener('click', refreshSubscription);

  byId('config-btn').addEventListener('click', openConfigDialog);
  byId('export-ips-btn').addEventListener('click', () => exportExitIps());
  byId('export-direct-btn').addEventListener('click', () => exportExitIps('direct'));
  byId('pool-create-all').addEventListener('click', () => createPools(creatablePorts()));
  byId('pool-sync').addEventListener('click', syncPools);
  byId('config-close').addEventListener('click', closeConfigDialog);
  byId('config-cancel').addEventListener('click', closeConfigDialog);
  byId('exit-config-form').addEventListener('submit', applyExitConfig);

  byId('exit-minus').addEventListener('click', () => {
    ui.config.maxExits = clampExitCount(ui.config.maxExits - 1);
    byId('exit-count').value = String(ui.config.maxExits);
    setConfigError('');
    renderCandidateList();
  });
  byId('exit-plus').addEventListener('click', () => {
    ui.config.maxExits = clampExitCount(ui.config.maxExits + 1);
    byId('exit-count').value = String(ui.config.maxExits);
    setConfigError('');
    renderCandidateList();
  });
  byId('exit-count').addEventListener('change', (event) => {
    ui.config.maxExits = clampExitCount(event.target.value);
    event.target.value = String(ui.config.maxExits);
    setConfigError('');
    renderCandidateList();
  });
  byId('auto-select').addEventListener('change', (event) => {
    ui.config.auto = event.target.checked;
    setConfigError('');
    renderCandidateList();
  });
  byId('candidate-search').addEventListener('input', (event) => {
    ui.config.query = event.target.value;
    renderCandidateList();
  });

  const dialog = byId('exit-config-dialog');
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) {
      closeConfigDialog();
    }
  });
  dialog.addEventListener('close', () => setConfigError(''));

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && ui.auto) {
      refresh();
    }
  });
}

function init() {
  const endpoint = byId('footer-endpoint');
  if (endpoint) {
    endpoint.textContent = window.location.host;
  }
  bind();
  render();
  refresh();
  armTimer();
}

init();
