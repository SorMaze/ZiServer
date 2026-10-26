import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function stringOption(name, fallback = '') {
  const entry = process.argv.find((value) => value.startsWith(`--${name}=`));
  return entry ? entry.slice(name.length + 3) : fallback;
}

function numberOption(name, fallback) {
  const value = stringOption(name);
  if (value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`--${name} must be a non-negative integer`);
  }
  return parsed;
}

async function freePort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

function httpRequest({ port, method = 'GET', requestPath = '/', headers = {}, body, tls = false }) {
  return new Promise((resolve, reject) => {
    const transport = tls ? https : http;
    const request = transport.request({
      host: '127.0.0.1',
      port,
      method,
      path: requestPath,
      headers,
      rejectUnauthorized: false,
      timeout: 10_000,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    request.on('timeout', () => request.destroy(new Error('HTTP request timed out')));
    request.on('error', reject);
    request.end(body);
  });
}

function h2Request(port, { method = 'GET', requestPath = '/', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const session = http2.connect(`https://127.0.0.1:${port}`, { rejectUnauthorized: false });
    const chunks = [];
    let status = 0;
    const timeout = setTimeout(() => {
      session.destroy();
      reject(new Error('HTTP/2 request timed out'));
    }, 10_000);
    session.on('error', reject);
    const request = session.request({ ':method': method, ':path': requestPath, ...headers });
    request.on('response', (responseHeaders) => { status = responseHeaders[':status']; });
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('error', reject);
    request.on('end', () => {
      clearTimeout(timeout);
      session.close();
      resolve({ status, body: Buffer.concat(chunks).toString('utf8'), alpn: session.alpnProtocol });
    });
    request.end(body);
  });
}

async function streamingRequest(port, tls, useHttp2) {
  return new Promise((resolve, reject) => {
    let session;
    let request;
    const chunks = [];
    let continued = false;
    const timeout = setTimeout(() => {
      const protocol = useHttp2 ? 'HTTP/2' : 'HTTP/1.1';
      const phase = continued ? 'continuation sent' : 'waiting for first response chunk';
      const received = Buffer.concat(chunks).toString('utf8');
      const error = new Error(`${protocol} streaming request timed out (${phase}), received=${JSON.stringify(received)}`);
      session?.destroy();
      request?.destroy(error);
      reject(error);
    }, 10_000);
    const fail = (error) => {
      clearTimeout(timeout);
      session?.destroy();
      reject(error);
    };
    const onResponse = (status) => {
      if (status !== 200) fail(new Error(`streaming response status ${status}`));
    };
    const onData = (chunk) => {
      chunks.push(chunk);
      if (!continued && !useHttp2) {
        continued = true;
        request.end('bravo\n');
      }
    };
    const onEnd = () => {
      clearTimeout(timeout);
      const body = Buffer.concat(chunks).toString('utf8');
      session?.close();
      if (body !== 'alpha\nbravo\n') {
        reject(new Error(`unexpected streaming response ${JSON.stringify(body)}`));
      } else {
        resolve();
      }
    };

    if (useHttp2) {
      session = http2.connect(`https://127.0.0.1:${port}`, { rejectUnauthorized: false });
      session.on('error', fail);
      request = session.request({ ':method': 'POST', ':path': '/stream/echo' }, { endStream: false });
      request.on('response', (headers) => onResponse(headers[':status']));
    } else {
      request = (tls ? https : http).request({
        host: '127.0.0.1',
        port,
        method: 'POST',
        path: '/stream/echo',
        headers: { 'Transfer-Encoding': 'chunked' },
        rejectUnauthorized: false,
      }, (response) => {
        onResponse(response.statusCode);
        response.on('data', onData);
        response.on('end', onEnd);
      });
    }
    request.on('error', fail);
    if (useHttp2) {
      request.on('data', onData);
      request.on('end', onEnd);
      setTimeout(() => {
        if (!continued && !request.destroyed && !request.writableEnded) {
          continued = true;
          request.end('bravo\n');
        }
      }, 300);
    }
    request.write('alpha\n');
  });
}

async function runSoak(port, duration) {
  if (duration === 0) return;
  const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'http2-soak.mjs');
  const result = spawnSync(process.execPath, [
    script,
    `--origin=https://127.0.0.1:${port}`,
    '--connections=2',
    '--streams=4',
    `--duration=${duration}`,
  ], { encoding: 'utf8', timeout: (duration + 30) * 1000 });
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  assert.equal(result.status, 0, 'HTTP/2 soak failed');
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = path.resolve(stringOption('server', path.join('zig-out', 'bin', process.platform === 'win32' ? 'ziserver.exe' : 'ziserver')));
const tlsCert = stringOption('tls-cert');
const tlsKey = stringOption('tls-key');
const logFile = stringOption('log-file');
const soakDuration = numberOption('soak-duration', 0);
const httpPort = numberOption('http-port', 0) || await freePort();
const requestedHttpsPort = numberOption('https-port', 0);
let httpsPort = requestedHttpsPort;
while (httpsPort === 0 || (requestedHttpsPort === 0 && httpsPort === httpPort)) httpsPort = await freePort();
assert.equal(Boolean(tlsCert), Boolean(tlsKey), '--tls-cert and --tls-key must be provided together');
assert.ok(fs.existsSync(server), `server not found: ${server}`);
assert.notEqual(httpPort, httpsPort, 'HTTP and HTTPS ports must differ');

const args = [
  '--host=127.0.0.1',
  `--http-port=${httpPort}`,
  `--https-port=${httpsPort}`,
  '--no-access-log',
  '--keep-alive=1000000',
  '--log-format=json',
  '--log-color=off',
];
if (tlsCert) {
  args.push(`--tls-cert=${path.resolve(tlsCert)}`, `--tls-key=${path.resolve(tlsKey)}`, '--http2=on');
} else {
  args.push('--tls=off');
}
const staticDir = path.join(root, 'zig-out', 'public');
if (fs.existsSync(staticDir)) args.push(`--static-dir=${staticDir}`);

const child = spawn(server, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
let logs = '';
child.stdout.on('data', (chunk) => { logs += chunk; });
child.stderr.on('data', (chunk) => { logs += chunk; });
const exited = new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal })));

async function stopChild() {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill();
  await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5_000))]);
}

try {
  let ready = false;
  const readinessDeadline = Date.now() + 15_000;
  while (Date.now() < readinessDeadline) {
    if (child.exitCode !== null) throw new Error(`server exited during startup with ${child.exitCode}`);
    try {
      const response = await httpRequest({ port: httpPort, requestPath: '/health' });
      if (response.status === 200) {
        ready = true;
        break;
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.ok(ready, 'server did not become ready');

  const home = await httpRequest({ port: httpPort });
  assert.equal(home.status, 200);
  assert.match(home.body, /ZiServer/);
  const asset = await httpRequest({ port: httpPort, requestPath: '/assets/style.css' });
  assert.equal(asset.status, 200);
  assert.match(asset.headers['content-type'], /text\/css/);
  assert.equal((await httpRequest({ port: httpPort, requestPath: '/missing' })).status, 404);
  const echo = await httpRequest({
    port: httpPort,
    method: 'POST',
    requestPath: '/api/echo',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: 'smoke', count: 2 }),
  });
  assert.equal(echo.status, 200);
  const echoedJson = JSON.parse(echo.body);
  assert.equal(echoedJson.message, 'smoke');
  assert.equal(echoedJson.count, 2);
  await streamingRequest(httpPort, false, false);

  if (tlsCert) {
    const secureHome = await httpRequest({ port: httpsPort, tls: true });
    assert.equal(secureHome.status, 200);
    const h2Home = await h2Request(httpsPort);
    assert.equal(h2Home.status, 200);
    assert.equal(h2Home.alpn, 'h2');
    await streamingRequest(httpsPort, true, false);
    await streamingRequest(httpsPort, true, true);
    await runSoak(httpsPort, soakDuration);
  }

  if (process.platform !== 'win32') {
    child.kill('SIGTERM');
    const result = await Promise.race([
      exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error('graceful shutdown timed out')), 15_000)),
    ]);
    assert.equal(result.code, 0, `server exited with ${result.code ?? result.signal}`);
    assert.match(logs, /shutdown_complete/);
  }
  console.log(JSON.stringify({ ok: true, http: true, tls: Boolean(tlsCert), http2: Boolean(tlsCert), streaming: true, soak_seconds: tlsCert ? soakDuration : 0 }));
} catch (error) {
  console.error(logs);
  throw error;
} finally {
  await stopChild();
  if (logFile) {
    fs.mkdirSync(path.dirname(path.resolve(logFile)), { recursive: true });
    fs.writeFileSync(logFile, logs);
  }
}
