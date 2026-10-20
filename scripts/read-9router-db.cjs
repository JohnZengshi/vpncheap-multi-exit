#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const DEFAULT_DB = path.join(
  process.env.APPDATA || '',
  '9router',
  'db',
  'data.sqlite'
);

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const showSensitive = args.includes('--show-sensitive');
const dbPath = args.find((arg) => !arg.startsWith('--')) || DEFAULT_DB;

function shortHash(value, length = 16) {
  if (value === null || value === undefined || value === '') return null;
  return crypto.createHash('sha256').update(String(value)).digest('hex').slice(0, length);
}

function parseJson(value) {
  if (typeof value !== 'string' || value.length === 0) return {};
  try {
    return JSON.parse(value) || {};
  } catch {
    return null;
  }
}

function parseUrl(value) {
  try {
    return new URL(String(value));
  } catch {
    return null;
  }
}

function openDatabase(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Database not found: ${filePath}`);
  }

  try {
    const sqlite = require('node:sqlite');
    if (!sqlite.DatabaseSync) throw new Error('node:sqlite DatabaseSync unavailable');
    return {
      db: new sqlite.DatabaseSync(filePath, { readOnly: true }),
      driver: 'node:sqlite'
    };
  } catch (nodeSqliteError) {
    const betterSqlitePath = path.join(
      process.env.APPDATA || '',
      '9router',
      'runtime',
      'node_modules',
      'better-sqlite3'
    );
    const BetterSqlite3 = require(betterSqlitePath);
    return {
      db: new BetterSqlite3(filePath, { readonly: true, fileMustExist: true }),
      driver: 'better-sqlite3',
      fallbackReason: nodeSqliteError.message
    };
  }
}

function all(db, sql, params = []) {
  const statement = db.prepare(sql);
  return statement.all(...params);
}

function tableExists(db, tableName) {
  const rows = all(
    db,
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [tableName]
  );
  return rows.length > 0;
}

function tableSchema(db, tableName) {
  return all(
    db,
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
    [tableName]
  ).map((row) => row.sql);
}

function tableColumns(db, tableName) {
  return all(db, `PRAGMA table_info(${tableName})`).map((row) => ({
    name: row.name,
    type: row.type,
    notNull: row.notnull === 1,
    primaryKey: row.pk > 0
  }));
}

function redactProxyUrl(proxyUrl) {
  if (showSensitive) {
    return { proxyUrl };
  }

  const parsed = parseUrl(proxyUrl);
  return {
    proxyUrlHash: shortHash(proxyUrl, 20),
    proxyUrlKind: parsed ? parsed.protocol.replace(':', '') : 'unknown',
    proxyUrlHostHash: parsed ? shortHash(parsed.hostname, 16) : null,
    proxyUrlPort: parsed && parsed.port ? Number(parsed.port) : null,
    proxyUrlIsLoopback: parsed
      ? ['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname)
      : false
  };
}

function poolSummary(row) {
  const data = parseJson(row.data);
  const base = {
    id: row.id,
    idHash: shortHash(row.id),
    dbIsActive: row.isActive === 1,
    dbTestStatus: row.testStatus,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt
  };

  if (!data) {
    return { ...base, dataParseError: true };
  }

  return {
    ...base,
    name: data.name,
    type: data.type,
    isActive: data.isActive,
    strictProxy: data.strictProxy,
    noProxyCount: typeof data.noProxy === 'string' && data.noProxy.length > 0
      ? data.noProxy.split(',').filter(Boolean).length
      : 0,
    lastTestedAt: data.lastTestedAt,
    lastErrorHash: data.lastError ? shortHash(data.lastError, 20) : null,
    ...redactProxyUrl(data.proxyUrl)
  };
}

function connectionSummary(row) {
  const data = parseJson(row.data);
  const base = {
    id: row.id,
    idHash: shortHash(row.id),
    provider: row.provider,
    authType: row.authType,
    name: row.name,
    emailHash: row.email ? shortHash(row.email, 16) : null,
    priority: row.priority,
    isActive: row.isActive === 1,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt
  };

  if (!data) {
    return { ...base, dataParseError: true };
  }

  const proxyPoolId = data.proxyPoolId || data.providerSpecificData?.proxyPoolId || null;
  const maybeKey = data.apiKey || data.cookie;

  return {
    ...base,
    proxyPoolId,
    proxyPoolIdHash: proxyPoolId ? shortHash(proxyPoolId) : null,
    hasApiKey: typeof maybeKey === 'string' && maybeKey.length > 0,
    connectionProxyEnabled: data.connectionProxyEnabled === true,
    connectionProxyUrlHash: data.connectionProxyUrl
      ? shortHash(data.connectionProxyUrl, 20)
      : null
  };
}

let opened;
try {
  opened = openDatabase(dbPath);
  const db = opened.db;

  const tables = all(
    db,
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
  ).map((row) => row.name);

  const poolRows = tableExists(db, 'proxyPools')
    ? all(db, 'SELECT * FROM proxyPools ORDER BY createdAt')
    : [];
  const connectionRows = tableExists(db, 'providerConnections')
    ? all(db, 'SELECT * FROM providerConnections ORDER BY createdAt')
    : [];

  const result = {
    database: {
      path: dbPath,
      driver: opened.driver,
      fallbackReason: opened.fallbackReason || null
    },
    tables,
    schemas: {
      proxyPools: tableExists(db, 'proxyPools')
        ? { columns: tableColumns(db, 'proxyPools'), sql: tableSchema(db, 'proxyPools') }
        : null,
      providerConnections: tableExists(db, 'providerConnections')
        ? { columns: tableColumns(db, 'providerConnections'), sql: tableSchema(db, 'providerConnections') }
        : null
    },
    proxyPools: poolRows.map(poolSummary),
    providerConnections: connectionRows.map(connectionSummary)
  };

  if (jsonOutput) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } else {
    console.log(`Database: ${result.database.path}`);
    console.log(`Driver: ${result.database.driver}`);
    console.log(`Tables: ${result.tables.join(', ')}`);
    console.log('');
    console.log(`Proxy pools: ${result.proxyPools.length}`);
    for (const pool of result.proxyPools) {
      console.log(JSON.stringify(pool));
    }
    console.log('');
    console.log(`Provider connections: ${result.providerConnections.length}`);
    for (const connection of result.providerConnections) {
      console.log(JSON.stringify(connection));
    }
  }

  db.close();
} catch (error) {
  console.error(`read-9router-db failed: ${error.message}`);
  if (opened?.db?.close) {
    try {
      opened.db.close();
    } catch {
      // Ignore close failures after an error.
    }
  }
  process.exitCode = 1;
}
