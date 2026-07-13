import http2 from 'node:http2';
import cluster from 'node:cluster';
import fs from 'node:fs';

function numberOption(name, fallback, min) {
  const entry = process.argv.find((value) => value.startsWith(`--${name}=`));
  if (!entry) return fallback;
  const parsed = Number(entry.slice(name.length + 3));
  if (!Number.isSafeInteger(parsed) || parsed < min) {
    throw new Error(`--${name} must be an integer >= ${min}`);
  }
  return parsed;
}

function stringOption(name, fallback) {
  const entry = process.argv.find((value) => value.startsWith(`--${name}=`));
  return entry ? entry.slice(name.length + 3) : fallback;
}

const origin = stringOption('origin', 'https://127.0.0.1:18443');
const path = stringOption('path', '/about');
const method = stringOption('method', 'GET').toUpperCase();
const bodyFile = stringOption('body-file', '');
const contentType = stringOption('content-type', 'application/json');
const connections = numberOption('connections', 8, 1);
const streams = numberOption('streams', 8, 1);
const durationSeconds = numberOption('duration', 30, 1);
const graceSeconds = numberOption('grace', 10, 1);
const processes = numberOption('processes', 1, 1);
const requestBody = bodyFile === '' ? null : fs.readFileSync(bodyFile);

if (method !== 'GET' && method !== 'POST' && method !== 'PUT' && method !== 'PATCH') {
  throw new Error('--method must be GET, POST, PUT, or PATCH');
}
if (requestBody !== null && method === 'GET') {
  throw new Error('--body-file requires a request method with a body');
}

function mergeStats(total, next) {
  total.attempted += next.attempted;
  total.success += next.success;
  total.failed += next.failed;
  total.bytes += next.bytes;
  total.status_errors += next.status_errors;
  total.session_errors += next.session_errors;
  total.goaways += next.goaways;
  total.reconnects += next.reconnects;
  for (const [code, count] of Object.entries(next.session_error_codes)) {
    total.session_error_codes[code] = (total.session_error_codes[code] ?? 0) + count;
  }
  for (const [status, count] of Object.entries(next.status_codes)) {
    total.status_codes[status] = (total.status_codes[status] ?? 0) + count;
  }
}

async function runClusterPrimary() {
  const startedAt = process.hrtime.bigint();
  const total = {
    attempted: 0,
    success: 0,
    failed: 0,
    bytes: 0,
    status_errors: 0,
    status_codes: {},
    session_errors: 0,
    session_error_codes: {},
    goaways: 0,
    reconnects: 0,
  };
  const reported = new Set();
  let exited = 0;
  let crashed = 0;
  let workersWithErrors = 0;

  const finished = new Promise((resolve) => {
    cluster.on('message', (worker, message) => {
      if (message?.type !== 'http2-soak-result' || reported.has(worker.id)) return;
      reported.add(worker.id);
      mergeStats(total, message.stats);
      if (message.stats.failed !== 0 || message.stats.session_errors !== 0) {
        workersWithErrors += 1;
      }
    });
    cluster.on('exit', (worker, code, signal) => {
      exited += 1;
      if (!reported.has(worker.id) || signal != null) crashed += 1;
      if (exited === processes) resolve();
    });
  });

  for (let index = 0; index < processes; index += 1) cluster.fork();
  await finished;

  const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
  total.processes = processes;
  total.processes_reported = reported.size;
  total.processes_crashed = crashed;
  total.processes_with_errors = workersWithErrors;
  total.rps = Number((total.success / (elapsedMs / 1000)).toFixed(2));
  total.elapsed_ms = Math.round(elapsedMs);
  console.log(JSON.stringify(total));
  process.exitCode = total.failed === 0 && total.session_errors === 0 && crashed === 0 ? 0 : 1;
}

if (cluster.isPrimary && processes > 1) {
  await runClusterPrimary();
} else {
  await runSoakWorker();
}

async function runSoakWorker() {

const startedAt = process.hrtime.bigint();
const deadline = Date.now() + durationSeconds * 1000;
const stats = {
  attempted: 0,
  success: 0,
  failed: 0,
  bytes: 0,
  status_errors: 0,
  status_codes: {},
  session_errors: 0,
  session_error_codes: {},
  goaways: 0,
  reconnects: 0,
};
const slots = [];
let inFlight = 0;
let accepting = true;

function scheduleReconnect(slot) {
  if (!accepting || slot.reconnecting) return;
  slot.reconnecting = true;
  setTimeout(() => {
    slot.reconnecting = false;
    if (!accepting) return;
    stats.reconnects += 1;
    connectSlot(slot);
  }, 5);
}

function connectSlot(slot) {
  const client = http2.connect(origin, { rejectUnauthorized: false });
  slot.client = client;
  slot.accepting = true;
  slot.hadError = false;
  client.on('error', (error) => {
    if (!slot.hadError) {
      slot.hadError = true;
      stats.session_errors += 1;
      const code = error?.code ?? 'UNKNOWN';
      stats.session_error_codes[code] = (stats.session_error_codes[code] ?? 0) + 1;
    }
  });
  client.on('goaway', () => {
    if (slot.client !== client || !slot.accepting) return;
    slot.accepting = false;
    stats.goaways += 1;
    scheduleReconnect(slot);
    // A GOAWAY retires this session. Send the peer our own GOAWAY so it can
    // release the idle connection after currently-open streams drain.
    client.close();
  });
  client.on('close', () => {
    if (slot.client !== client || !slot.accepting) return;
    slot.accepting = false;
    scheduleReconnect(slot);
  });
  client.on('connect', () => {
    for (let stream = 0; stream < streams; stream += 1) launchRequest(slot);
  });
}

function launchRequest(slot) {
  const client = slot.client;
  if (!accepting || !slot.accepting || client.closed || client.destroyed) return;
  stats.attempted += 1;
  inFlight += 1;
  let status = 0;
  let bytes = 0;
  let settled = false;

  const finish = (ok) => {
    if (settled) return;
    settled = true;
    inFlight -= 1;
    if (ok && status >= 200 && status < 400) {
      stats.success += 1;
      stats.bytes += bytes;
    } else {
      stats.failed += 1;
      if (status !== 0) {
        stats.status_errors += 1;
        stats.status_codes[status] = (stats.status_codes[status] ?? 0) + 1;
      }
    }
    if (accepting && slot.accepting && slot.client === client) launchRequest(slot);
  };

  let request;
  try {
    const headers = { ':method': method, ':path': path };
    if (requestBody !== null) {
      headers['content-type'] = contentType;
      headers['content-length'] = String(requestBody.length);
    }
    request = client.request(headers);
  } catch {
    finish(false);
    return;
  }
  request.on('response', (headers) => { status = Number(headers[':status'] ?? 0); });
  request.on('data', (chunk) => { bytes += chunk.length; });
  request.on('end', () => finish(true));
  request.on('error', () => finish(false));
  request.end(requestBody ?? undefined);
}

for (let connection = 0; connection < connections; connection += 1) {
  const slot = { client: null, accepting: false, reconnecting: false, hadError: false };
  slots.push(slot);
  connectSlot(slot);
}

await new Promise((resolve) => setTimeout(resolve, durationSeconds * 1000));
accepting = false;

const graceDeadline = Date.now() + graceSeconds * 1000;
while (inFlight !== 0 && Date.now() < graceDeadline) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}

for (const { client } of slots) {
  if (inFlight === 0) client.close();
  else client.destroy();
}

const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
if (inFlight !== 0) stats.failed += inFlight;
stats.rps = Number((stats.success / (elapsedMs / 1000)).toFixed(2));
stats.elapsed_ms = Math.round(elapsedMs);
if (process.send) {
  process.send({ type: 'http2-soak-result', stats }, () => {
    process.exit(stats.failed === 0 && stats.session_errors === 0 ? 0 : 1);
  });
} else {
  console.log(JSON.stringify(stats));
  process.exitCode = stats.failed === 0 && stats.session_errors === 0 ? 0 : 1;
}
}
