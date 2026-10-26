import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import http2 from 'node:http2';
import net from 'node:net';
import path from 'node:path';

function option(name, fallback = '') {
  return process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
}
const fixture = path.resolve(option('fixtures', '.zig-cache/tls-reload-fixtures'));
const server = path.resolve(option('server', path.join('zig-out', 'bin', process.platform === 'win32' ? 'ziserver.exe' : 'ziserver')));
const control = path.join(fixture, 'control.json');
const ca = fs.readFileSync(path.join(fixture, 'ca.pem'));
const fingerprints = JSON.parse(fs.readFileSync(path.join(fixture, 'fingerprints.json'), 'utf8'));
const read = file => fs.readFileSync(path.join(fixture, file));
const active = (revision, extra = {}) => ({ revision, cert_file: 'server-b.pem', key_file: 'server-b.key', ...extra });
let child;
let logs = '';
let passed = 0;
const sessions = [];
const rawSockets = [];

async function freePort() {
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return port;
}
const httpPort = await freePort();
let httpsPort = await freePort();
while (httpsPort === httpPort) httpsPort = await freePort();

async function until(predicate, label) {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error(`timed out: ${label}`);
}
function writePolicy(policy) {
  fs.writeFileSync(`${control}.tmp`, JSON.stringify(policy));
  fs.renameSync(`${control}.tmp`, control);
}
async function apply(policy, expected = 'replaced') {
  const offset = logs.length;
  writePolicy(policy);
  const event = expected === 'failed' ? 'tls_control_failed' : `tls_certificate_${expected}`;
  await until(() => new RegExp(`${event}: revision=${policy.revision}(?: |$)`).test(logs.slice(offset)), `${event} ${policy.revision}`);
}
function request({ plain = false, identity, agent = false, session, tls12 = false } = {}) {
  return new Promise((resolve, reject) => {
    const req = (plain ? http : https).get({
      host: '127.0.0.1', port: plain ? httpPort : httpsPort, path: '/health',
      servername: 'localhost', ca, agent, session,
      ...(identity ? { cert: read(`${identity}.pem`), key: read(`${identity}.key`) } : {}),
      ...(tls12 ? { minVersion: 'TLSv1.2', maxVersion: 'TLSv1.2' } : {}),
    }, response => {
      const socket = response.socket;
      const result = {
        status: response.statusCode,
        fingerprint: plain ? null : socket.getPeerCertificate().fingerprint256?.replaceAll(':', '').toLowerCase(),
        session: plain ? null : socket.getSession(),
        reused: plain ? false : socket.isSessionReused(),
      };
      response.resume();
      response.once('end', () => resolve(result));
      response.once('error', reject);
    });
    req.setTimeout(2000, () => req.destroy(new Error('TLS test request timed out')));
    req.once('error', reject);
  });
}
async function accepted(identity) {
  assert.equal((await request({ identity })).status, 200);
}
async function rejected(identity) {
  await assert.rejects(request({ identity }));
}
async function check(name, test) {
  await test();
  passed++;
  console.log(`PASS ${name}`);
}
function connectH2(identity) {
  const session = http2.connect(`https://127.0.0.1:${httpsPort}`, {
    servername: 'localhost', ca,
    ...(identity ? { cert: read(`${identity}.pem`), key: read(`${identity}.key`) } : {}),
  });
  session.on('error', () => {});
  sessions.push(session);
  return session;
}
async function h2Health(session) {
  return new Promise((resolve, reject) => {
    const req = session.request({ ':path': '/health' });
    let status;
    req.on('response', headers => { status = headers[':status']; });
    req.resume();
    req.setTimeout(2000, () => req.destroy(new Error('HTTP2 test timed out')));
    req.once('error', reject);
    req.once('end', () => { assert.equal(status, 200); resolve(); });
  });
}
async function start() {
  child = spawn(server, [
    '--host=127.0.0.1', `--http-port=${httpPort}`, `--https-port=${httpsPort}`,
    `--tls-control=${control}`, '--tls-control-interval=50', '--http2=on', '--no-access-log', '--log-color=off',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', chunk => { logs += chunk; });
  child.stderr.on('data', chunk => { logs += chunk; });
  child.on('error', error => { logs += String(error); });
  await until(async () => {
    if (child.exitCode !== null) throw new Error(`server exited ${child.exitCode}`);
    try { return [200, 403].includes((await request({ plain: true })).status); } catch { return false; }
  }, 'server readiness');
}
async function stop() {
  for (const session of sessions) session.destroy();
  for (const socket of rawSockets) socket.destroy();
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.kill();
  let timeout;
  await Promise.race([exited, new Promise(resolve => { timeout = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000); })]);
  clearTimeout(timeout);
}

writePolicy(active(1, { cert_file: 'server-a.pem', key_file: 'server-a.key' }));
try {
  await start();
  const originalPid = child.pid;
  let oldSession;
  let ticket;
  await check('initial certificate and persistent HTTP2 session', async () => {
    const result = await request({ tls12: true });
    assert.equal(result.fingerprint, fingerprints['server-a'].cert);
    ticket = result.session;
    oldSession = connectH2();
    await h2Health(oldSession);
  });
  await check('atomic replacement preserves established connections and invalidates old tickets', async () => {
    await apply(active(2));
    const result = await request({ session: ticket, tls12: true });
    assert.equal(result.fingerprint, fingerprints['server-b'].cert);
    assert.equal(result.reused, false);
    await h2Health(oldSession);
    assert.equal(child.pid, originalPid);
  });
  await check('mismatched key and expired certificate retain the working credential', async () => {
    await apply(active(3, { cert_file: 'server-a.pem' }), 'failed');
    assert.equal((await request()).fingerprint, fingerprints['server-b'].cert);
    await apply(active(4, { cert_file: 'expired-server.pem', key_file: 'expired-server.key' }), 'failed');
    assert.equal((await request()).fingerprint, fingerprints['server-b'].cert);
  });
  await check('stale revision cannot roll back the certificate', async () => {
    writePolicy(active(1, { cert_file: 'server-a.pem', key_file: 'server-a.key' }));
    await new Promise(resolve => setTimeout(resolve, 150));
    assert.equal((await request()).fingerprint, fingerprints['server-b'].cert);
  });
  await check('SPKI revocation closes old sessions and refuses a denied replacement', async () => {
    const partialHandshakes = await Promise.all(Array.from({ length: 8 }, () => new Promise((resolve, reject) => {
      const socket = net.connect(httpsPort, '127.0.0.1', () => {
        socket.write(Buffer.from([0x16, 0x03, 0x03, 0x00, 0x64, 0x01, 0x00, 0x00]));
        resolve(socket);
      });
      socket.on('error', () => {});
      socket.once('error', reject);
      rawSockets.push(socket);
    })));
    await new Promise(resolve => setTimeout(resolve, 100));
    const deny = [fingerprints['server-b'].spki];
    await apply(active(5, { cert_file: 'server-a.pem', key_file: 'server-a.key', deny_spki_sha256: deny }));
    await until(() => oldSession.destroyed, 'revoked session closure');
    await until(() => partialHandshakes.every(socket => socket.destroyed), 'revoked in-flight handshake closure');
    await apply(active(6, { deny_spki_sha256: deny }), 'failed');
    assert.equal((await request()).fingerprint, fingerprints['server-a'].cert);
  });
  await check('emergency revocation blocks new handshakes while HTTP remains available', async () => {
    oldSession = connectH2();
    await h2Health(oldSession);
    await apply({ revision: 7, revoked: true }, 'revoked');
    await rejected();
    await until(() => oldSession.destroyed, 'emergency session closure');
    assert.equal((await request({ plain: true })).status, 200);
  });
  await check('revocation survives restart; replacement recovers without another restart', async () => {
    await stop();
    await start();
    await rejected();
    await apply(active(8));
    await accepted();
  });
  const crlPolicy = { client_ca_file: 'ca.pem', client_crl_file: 'empty.crl' };
  await check('mTLS requires a trusted client and applies a hot CRL update', async () => {
    await apply(active(9, crlPolicy));
    assert.equal((await request({ plain: true })).status, 403);
    await rejected();
    await rejected('stranger');
    await rejected('server-a');
    await accepted('client');
    await accepted('second-client');
    const authenticated = await request({ identity: 'client', tls12: true });
    await assert.rejects(request({ session: authenticated.session, tls12: true }));
    assert.equal((await request({ identity: 'client', session: authenticated.session, tls12: true })).reused, false);
    oldSession = connectH2('client');
    await h2Health(oldSession);
    await apply(active(10, { ...crlPolicy, client_crl_file: 'revoked.crl' }));
    await until(() => oldSession.destroyed, 'client revocation session closure');
    await rejected('client');
    await accepted('second-client');
  });
  await check('expired and forged CRLs cannot replace the current trust policy', async () => {
    await apply(active(11, { ...crlPolicy, client_crl_file: 'expired.crl' }), 'failed');
    await apply(active(12, { ...crlPolicy, client_crl_file: 'forged.crl' }), 'failed');
    await rejected('client');
    await accepted('second-client');
  });
  const ocspPolicy = { client_ca_file: 'ca.pem', client_ocsp_files: ['good.der'] };
  await check('signed OCSP GOOD admits only the matching client', async () => {
    await apply(active(13, ocspPolicy));
    await accepted('client');
    await rejected('second-client');
    await rejected('stranger');
  });
  await check('OCSP UNKNOWN fails closed and SHA256 CertIDs are supported', async () => {
    await apply(active(14, { ...ocspPolicy, client_ocsp_files: ['unknown.der'] }));
    await rejected('client');
    await apply(active(15, { ...ocspPolicy, client_ocsp_files: ['good-sha256.der'] }));
    await accepted('client');
  });
  await check('OCSP REVOKED refuses the client', async () => {
    await apply(active(16, { ...ocspPolicy, client_ocsp_files: ['revoked.der'] }));
    await rejected('client');
  });
  await check('expired, missing-expiry and forged OCSP responses are rejected', async () => {
    for (const [revision, file] of [[17, 'expired.der'], [18, 'missing-next.der'], [19, 'forged.der']]) {
      await apply(active(revision, { ...ocspPolicy, client_ocsp_files: [file] }), 'failed');
      await rejected('client');
    }
  });
  await check('a GOOD OCSP response cannot override a signed REVOKED response', async () => {
    await apply(active(20, { ...ocspPolicy, client_ocsp_files: ['good.der', 'revoked.der'] }));
    await rejected('client');
  });
  await check('combined CRL/OCSP policy requires both checks to pass', async () => {
    await apply(active(21, { ...crlPolicy, ...ocspPolicy }));
    await accepted('client');
    await apply(active(22, { ...crlPolicy, ...ocspPolicy, client_crl_file: 'revoked.crl' }));
    await rejected('client');
  });
  await check('client public-key blocklist applies to mTLS authentication', async () => {
    await apply(active(23, { ...crlPolicy, deny_spki_sha256: [fingerprints.client.spki] }));
    await rejected('client');
    await accepted('second-client');
  });
  await check('issuer blocklist is checked across the configured server chain', async () => {
    await apply(active(24, { cert_file: 'server-chain.pem', key_file: 'server-a.key', deny_spki_sha256: [fingerprints.ca.spki] }), 'failed');
    await accepted('second-client');
  });
  await check('denied active certificate stays disabled when replacement fails', async () => {
    await apply(active(25, { cert_file: 'missing.pem', deny_cert_sha256: [fingerprints['server-b'].cert] }), 'failed');
    await rejected();
    assert.equal((await request({ plain: true })).status, 403);
    await apply(active(26, { cert_file: 'server-a.pem', key_file: 'server-a.key', disable_client_auth: true }));
    await accepted();
  });
  await check('concurrent handshakes survive repeated certificate replacements', async () => {
    const clients = Promise.all(Array.from({ length: 8 }, async () => {
      for (let i = 0; i < 12; i++) await accepted();
    }));
    for (let revision = 27; revision <= 30; revision++) {
      const name = revision % 2 ? 'server-a' : 'server-b';
      await apply(active(revision, { cert_file: `${name}.pem`, key_file: `${name}.key` }));
    }
    await clients;
  });
  await check('client authentication cannot be silently removed by a certificate rotation', async () => {
    await apply(active(31, crlPolicy));
    await apply(active(32), 'failed');
    await rejected();
    await accepted('client');
    await apply(active(33, { disable_client_auth: true }));
    await accepted();
  });
  await check('OCSP requires the issuer or its authorized delegated responder', async () => {
    await apply(active(34, { client_ca_file: 'multi-ca.pem', client_ocsp_files: ['forged.der'] }), 'failed');
    await apply(active(35, { ...ocspPolicy, client_ocsp_files: ['bad-responder.der'] }), 'failed');
    await apply(active(36, { ...ocspPolicy, client_ocsp_files: ['delegated.der'] }));
    await accepted('client');
  });
  await check('mTLS emergency disable remains closed to plaintext after restart', async () => {
    await apply({ revision: 37, revoked: true, client_ca_file: 'ca.pem' }, 'revoked');
    assert.equal((await request({ plain: true })).status, 403);
    await stop();
    await start();
    await rejected('client');
    assert.equal((await request({ plain: true })).status, 403);
    await apply(active(38, ocspPolicy));
    await accepted('client');
  });
  await check('client CA changes and issuer-key revocation apply without restart', async () => {
    const policy = { client_ca_file: 'other-ca.pem', client_crl_file: 'other-empty.crl' };
    await apply(active(39, policy));
    await rejected('client');
    await accepted('stranger');
    await apply(active(40, { ...policy, deny_spki_sha256: [fingerprints['other-ca'].spki] }));
    await rejected('stranger');
  });
  console.log(JSON.stringify({ ok: true, checks: passed, server: path.basename(server) }));
} catch (error) {
  console.error(logs);
  throw error;
} finally {
  await stop();
  const logFile = option('log-file', path.join(fixture, 'server.log'));
  fs.mkdirSync(path.dirname(logFile), { recursive: true });
  fs.writeFileSync(logFile, logs);
}
