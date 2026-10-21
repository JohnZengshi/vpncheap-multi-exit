'use strict';

const REFRESH_MS = 5000;
const MAX_HISTORY = 60;
const SVG_NS = 'http://www.w3.org/2000/svg';
const AUTO_KEY = 'exit-control.auto-refresh';

const STATE_LABELS = {
  healthy: '健康',
  unhealthy: '异常',
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
  query: '',
  auto: readAutoPreference(),
  history: new Map(),
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
    const results = (result && Array.isArray(result.results)) ? result.results : [];
    const failed = results.filter((item) => item.error);
    const untested = results.filter((item) => !item.error && item.testStatus !== 'active');
    if (failed.length) {
      showToast(`${failed.length} 个代理池创建失败`);
    } else if (untested.length) {
      showToast(`已创建 ${results.length} 个，${untested.length} 个测试未通过`);
    } else {
      showToast(`已创建 ${results.length} 个代理池，测试通过`);
    }
  } catch (error) {
    showToast(error && error.message ? error.message : '创建失败');
  } finally {
    ui.poolBusy = false;
    ui.poolPending = new Set();
    await refresh();
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

function buildExitRow(exit, poolPorts) {
  const tone = exitTone(exit);
  const row = make('tr');
  row.dataset.tone = tone;

  const nodeCell = make('td', 'cell-node');
  nodeCell.appendChild(make('div', 'node-name', exit.nodeName || '未命名节点'));
  nodeCell.appendChild(make('div', 'node-hash', exit.nodeHash || '—'));
  row.appendChild(nodeCell);

  const endpointCell = make('td');
  const endpoint = exit.endpoint || (exit.port ? `127.0.0.1:${exit.port}` : '—');
  endpointCell.appendChild(chip(endpoint, null, 'mono'));
  if (poolPorts && Number(exit.port) > 0 && !poolPorts.has(Number(exit.port))) {
    const line = make('div', 'pool-missing');
    line.appendChild(badge('无代理池', 'warn'));
    const planItem = poolPlanByPort().get(Number(exit.port));
    if (planItem && planItem.action === 'create') {
      line.appendChild(poolCreateButton(Number(exit.port)));
    } else if (planItem && planItem.action === 'conflict') {
      line.appendChild(badge('名称冲突', 'bad'));
    }
    endpointCell.appendChild(line);
  }
  endpointCell.appendChild(cellSub('mixed 入口'));
  row.appendChild(endpointCell);

  const regionCell = make('td');
  const region = make('div', 'region');
  region.appendChild(make('span', 'region-code', exit.country || '—'));
  region.appendChild(make('span', 'region-protocol', exit.protocol || '未知协议'));
  regionCell.appendChild(region);
  row.appendChild(regionCell);

  const statusCell = make('td');
  statusCell.appendChild(statusLine(tone, exitStateLabel(exit)));
  if (!exit.processAlive) {
    statusCell.appendChild(cellSub('进程未运行'));
  } else if (exit.consecutiveFailures > 0) {
    statusCell.appendChild(cellSub(`连续失败 ${exit.consecutiveFailures} 次`));
  } else {
    statusCell.appendChild(cellSub(`pwsh.exe · ${PROCESS_LABELS[exit.processState] || exit.processState || '运行中'}`));
  }
  row.appendChild(statusCell);

  const httpCell = make('td');
  const httpStatus = String(exit.httpStatus || '');
  const httpTone = httpStatus === '204' ? 'accent' : httpStatus ? 'warn' : null;
  httpCell.appendChild(chip(httpStatus || '—', httpTone, 'mono'));
  row.appendChild(httpCell);

  const latencyCell = make('td');
  const latencyBox = make('div', 'latency');
  const history = ui.history.get(exit.nodeHash) || [];
  latencyBox.appendChild(sparkline(history, tone));
  const latency = Number(exit.latencyMs);
  latencyBox.appendChild(make('span', 'latency-value', Number.isFinite(latency) && latency > 0 ? `${Math.round(latency)} ms` : '—'));
  latencyCell.appendChild(latencyBox);
  row.appendChild(latencyCell);

  const hashCell = make('td');
  hashCell.appendChild(buildHashCell(exit.exitIpHash));
  row.appendChild(hashCell);

  const workerCell = make('td');
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
  row.appendChild(workerCell);

  const checkCell = make('td');
  checkCell.appendChild(make('div', 'pid', formatClock(exit.lastCheckAt)));
  const relative = formatRelative(exit.lastCheckAt);
  if (relative) {
    checkCell.appendChild(cellSub(relative));
  }
  row.appendChild(checkCell);

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
  const warnings = (ui.data && Array.isArray(ui.data.warnings)) ? ui.data.warnings : [];
  const pools = (ui.data && Array.isArray(ui.data.pools)) ? ui.data.pools : [];
  const poolPorts = warnings.includes('nine-router-unavailable')
    ? null
    : new Set(pools.map((pool) => Number(pool.port)).filter((port) => Number.isFinite(port) && port > 0));
  const healthy = exits.filter((exit) => exitTone(exit) === 'ok').length;
  const bad = exits.length - healthy;

  setText('count-all', String(exits.length));
  setText('count-healthy', String(healthy));
  setText('count-bad', String(bad));
  setText('exit-subtitle', exits.length
    ? `${exits.length} 个出口 · ${healthy} 个健康 · 本机回环`
    : '本地回环入口 · 暂无出口');

  const visible = exits.filter(exitMatches);
  const body = byId('exit-body');
  body.replaceChildren(...visible.map((exit) => buildExitRow(exit, poolPorts)));

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
  });

  setText('candidate-summary', `${filtered.length} / ${candidates.length} · 已选 ${config.selected.size}`);
  setText('config-subtitle', `当前 ${config.maxExits} 个并行出口 · 候选 ${candidates.length} 个`);

  if (!filtered.length) {
    const empty = make('div', 'candidate-empty', candidates.length ? '没有匹配的候选节点' : '候选节点尚未发布');
    list.replaceChildren(empty);
    return;
  }

  const fragment = document.createDocumentFragment();
  filtered.forEach((candidate) => {
    const hash = String(candidate.nodeHash || '');
    const checked = config.selected.has(hash);
    const atLimit = !checked && config.selected.size >= config.maxExits;
    const disabled = config.auto || atLimit;
    const row = make('label', 'candidate-row');
    row.classList.toggle('is-selected', checked);
    row.classList.toggle('is-disabled', disabled && !checked);

    const input = make('input');
    input.type = 'checkbox';
    input.checked = checked;
    input.disabled = disabled;
    input.setAttribute('aria-label', candidate.nodeName || hash);
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
    const metaText = [candidate.country, candidate.protocol].filter(Boolean).join(' · ');
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
      };
      throw new Error((result && labels[result.error]) || `HTTP ${response.status}`);
    }
    closeConfigDialog();
    showToast('出口配置已应用');
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
    setText('stat-pools-meta', '本工具托管');
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
  const managed = pools.filter((pool) => pool.managed).length;
  setText('stat-pools', `${managed}/${pools.length}`);
  setText('stat-pools-meta', `本工具托管 · 共 ${pools.length} 个`);

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
  const pools = (data && Array.isArray(data.pools)) ? data.pools.slice() : [];
  const connections = (data && Array.isArray(data.connections)) ? data.connections : [];
  const list = byId('pool-list');
  const empty = byId('pool-empty');

  if (!data) {
    setText('pool-subtitle', ui.error ? '服务不可达' : '读取中');
    list.replaceChildren();
    empty.hidden = false;
    return;
  }

  const createAll = byId('pool-create-all');
  const creatable = creatablePorts();
  createAll.hidden = creatable.length === 0 && !ui.poolBusy;
  createAll.disabled = Boolean(ui.poolBusy);
  setText('pool-create-all-label', ui.poolBusy ? '创建中' : `为 ${creatable.length} 个出口创建`);

  const managed = pools.filter((pool) => pool.managed).length;
  const passing = pools.filter((pool) => pool.testStatus === 'active').length;
  setText('pool-subtitle', `${pools.length} 个代理池 · ${managed} 个托管 · ${passing} 个测试通过`);

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
    title.appendChild(badge(pool.managed ? '本工具' : '原有', pool.managed ? 'accent' : null));
    main.appendChild(title);

    const bound = connections.filter((connection) => connection.poolId === pool.id);
    let boundText = '未绑定连接';
    if (bound.length) {
      const names = bound.slice(0, 3).map((connection) => providerLabel(connection.provider));
      boundText = `绑定 ${names.join('、')}${bound.length > 3 ? ` 等 ${bound.length} 个` : ''}`;
    } else if (Number(pool.boundConnectionCount) > 0) {
      boundText = `${pool.boundConnectionCount} 个连接绑定`;
    }
    main.appendChild(cellSub(boundText));
    row.appendChild(main);

    const endpoint = make('div', 'endpoint-line');
    const endpointText = pool.endpoint === 'LAN' ? '局域网' : (pool.endpoint || '—');
    endpoint.appendChild(chip(endpointText, pool.port ? null : 'warn', 'mono'));
    endpoint.appendChild(cellSub(`${String(pool.type || 'http').toUpperCase()}${pool.port ? ` · 端口 ${pool.port}` : ' · 非本机'}`));
    row.appendChild(endpoint);

    const badges = make('div', 'badge-row');
    const testTone = pool.testStatus === 'active' ? 'ok' : (pool.testStatus ? 'warn' : null);
    badges.appendChild(badge(pool.testStatus === 'active' ? '测试通过' : (pool.testStatus || '未测试'), testTone));
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
  setText('connection-subtitle', `${connections.length} 个连接 · ${bound.length} 个已绑定 · ${connections.length - bound.length} 个未绑定`);

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
  renderWarnings();
  renderStats();
  renderExits();
  renderPools();
  renderConnections();
  renderFlow();
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

  byId('config-btn').addEventListener('click', openConfigDialog);
  byId('pool-create-all').addEventListener('click', () => createPools(creatablePorts()));
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
