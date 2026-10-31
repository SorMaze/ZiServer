import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const option = name => process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3);
const server = path.resolve(option('server') ?? 'zig-out/bin/ziserver');
const cert = path.resolve(option('tls-cert'));
const key = path.resolve(option('tls-key'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const runtime = fs.mkdtempSync(path.join(os.tmpdir(), 'ziserver-h2-regression-'));
const sessions = [];
let logs = '';
let child;

async function freePort() {
  const listener = net.createServer();
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}
const httpPort = await freePort();
let httpsPort = await freePort();
while (httpPort === httpsPort) httpsPort = await freePort();

function plainHealth() {
  return new Promise((resolve, reject) => {
    const req = http.get(`http://127.0.0.1:${httpPort}/health`, res => {
      res.resume();
      res.once('end', () => resolve(res.statusCode));
    });
    req.once('error', reject);
    req.setTimeout(1000, () => req.destroy(new Error('HTTP readiness timed out')));
  });
}
function connect(options = {}) {
  const session = http2.connect(`https://127.0.0.1:${httpsPort}`, { rejectUnauthorized: false, ...options });
  session.on('error', () => {});
  sessions.push(session);
  return session;
}
function request(session, headers, body, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const req = session.request(headers);
    const chunks = [];
    let status;
    const timer = setTimeout(() => req.destroy(new Error('HTTP/2 regression request timed out')), timeout);
    req.once('response', response => { status = response[':status']; });
    req.on('data', chunk => chunks.push(chunk));
    req.once('error', reject);
    req.once('end', () => resolve({ status, body: Buffer.concat(chunks), ms: performance.now() - started }));
    req.once('close', () => {
      clearTimeout(timer);
      if (req.rstCode !== 0) reject(new Error(`RST_STREAM(${req.rstCode})`));
    });
    req.end(body);
  });
}
async function health(session) {
  const result = await request(session, { ':path': '/health' }, undefined, 1500);
  assert.equal(result.status, 200);
  return result.ms;
}
async function until(predicate, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await pause(20);
  }
  throw new Error(`timed out: ${label}`);
}

try {
  child = spawn(server, [
    '--host=127.0.0.1', `--http-port=${httpPort}`, `--https-port=${httpsPort}`,
    `--tls-cert=${cert}`, `--tls-key=${key}`, '--http2=on', '--workers=8',
    '--body-timeout=20000', '--no-page-cache-prewarm', '--rate-limit-strict=0',
    '--no-access-log', '--log-color=off',
  ], { cwd: runtime, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', chunk => { logs += chunk; });
  child.stderr.on('data', chunk => { logs += chunk; });
  child.on('error', error => { logs += String(error); });
  await until(async () => {
    if (child.exitCode !== null) throw new Error(`server exited ${child.exitCode}: ${logs}`);
    try { return await plainHealth() === 200; } catch { return false; }
  }, 'server readiness');

  // Start before receiving server SETTINGS, then send bodies much larger than
  // the queue. Check the actual files as well as the HTTP response.
  const session = connect();
  for (const size of [256 * 1024, 256 * 1024, 2 * 1024 * 1024]) {
    const body = Buffer.alloc(size, 0x5a);
    const result = await request(session, {
      ':method': 'PUT', ':path': '/upload/stream',
      'content-type': 'application/octet-stream', 'content-length': size,
      'x-upload-filename': 'regression.bin',
    }, body);
    assert.equal(result.status, 200);
    assert.equal(JSON.parse(result.body).file_bytes, size);
  }
  const uploads = fs.readdirSync(path.join(runtime, 'var/uploads/large'));
  assert.equal(uploads.length, 3);
  const sizes = uploads.map(file => {
    const body = fs.readFileSync(path.join(runtime, 'var/uploads/large', file));
    assert.ok(body.every(byte => byte === 0x5a));
    return body.length;
  }).sort((a, b) => a - b);
  assert.deepEqual(sizes, [256 * 1024, 256 * 1024, 2 * 1024 * 1024]);
  console.log('PASS streaming uploads preserve complete files across multiple flow-control windows');

  // Padding has its own flow-control accounting inside nghttp2.
  const padded = connect({ paddingStrategy: http2.constants.PADDING_STRATEGY_MAX });
  const paddedResult = await request(padded, {
    ':method': 'PUT', ':path': '/upload/stream', 'content-type': 'application/octet-stream',
    'x-upload-filename': 'padded.bin',
  }, Buffer.alloc(256 * 1024, 0x31));
  assert.equal(paddedResult.status, 200);
  assert.equal(JSON.parse(paddedResult.body).file_bytes, 256 * 1024);
  console.log('PASS padded DATA replenishes flow-control windows');

  const rejected = await request(session, {
    ':method': 'POST', ':path': '/api/echo', 'x-oversized': 'x'.repeat(5000),
  }, Buffer.alloc(256 * 1024));
  assert.equal(rejected.status, 431);
  await health(session);
  console.log('PASS rejected headers drain DATA without exhausting the stream window');

  const held = [];
  let published = 0;
  let unexpectedStatus;
  for (let i = 0; i < 32; i++) {
    const req = session.request({ ':method': 'POST', ':path': '/stream/echo' }, { endStream: false });
    req.on('error', () => {});
    req.once('response', headers => {
      if (headers[':status'] !== 200) unexpectedStatus = headers[':status'];
      published++;
    });
    req.resume();
    held.push(req);
  }
  try {
    await until(() => published === held.length, '32 handlers awaiting request bodies');
    assert.equal(unexpectedStatus, undefined);
    await health(session);
    await health(connect());
    console.log('PASS unfinished streams do not starve the same or another HTTP/2 connection');
  } finally {
    for (const req of held) req.close(http2.constants.NGHTTP2_CANCEL);
  }
  await health(session);

  const cancelMs = [];
  for (let i = 0; i < 5; i++) {
    const demo = session.request({ ':path': '/stream/demo' });
    demo.on('error', () => {});
    demo.resume();
    await Promise.race([
      once(demo, 'data'),
      new Promise((_, reject) => {
        const timer = setTimeout(() => reject(new Error('stream demo timed out')), 5000);
        timer.unref();
        demo.once('close', () => clearTimeout(timer));
      }),
    ]);
    demo.close(http2.constants.NGHTTP2_CANCEL);
    // Let the server enter cancellation before sending another request.
    await pause(20);
    cancelMs.push(await health(session));
  }
  cancelMs.sort((a, b) => a - b);
  assert.ok(cancelMs[2] < 180, `RST stalled the session: median ${cancelMs[2].toFixed(1)} ms`);
  console.log(`PASS RST interrupts handler sleep; median next-request latency ${cancelMs[2].toFixed(1)} ms`);
  console.log(JSON.stringify({ ok: true, checks: 5 }));
} catch (error) {
  process.stderr.write(logs);
  throw error;
} finally {
  for (const session of sessions) session.destroy();
  if (child && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    child.kill();
    await exited;
  }
  const logFile = option('log-file');
  if (logFile) {
    fs.mkdirSync(path.dirname(path.resolve(logFile)), { recursive: true });
    fs.writeFileSync(logFile, logs);
  }
  assert.equal(path.dirname(path.resolve(runtime)), path.resolve(os.tmpdir()));
  assert.ok(path.basename(runtime).startsWith('ziserver-h2-regression-'));
  fs.rmSync(runtime, { recursive: true, force: true });
}
