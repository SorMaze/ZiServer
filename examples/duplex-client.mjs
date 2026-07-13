import http from 'node:http';
import http2 from 'node:http2';

const useHttp2 = process.argv.includes('--http2');
const portArg = process.argv.find((value) => value.startsWith('--port='));
const port = Number(portArg?.slice('--port='.length) || (useHttp2 ? 18443 : 18080));
const bytesArg = process.argv.find((value) => value.startsWith('--bytes='));
const bytes = Number(bytesArg?.slice('--bytes='.length) || 0);
const chunks = bytes > 0 ? ['x'.repeat(bytes)] : ['alpha\n', 'bravo\n', 'charlie\n', 'delta\n'];
const started = performance.now();
const log = (message) => console.log(`[${Math.round(performance.now() - started)}ms] ${message}`);
const describe = (chunk) => chunk.length > 128 ? `<${chunk.length} bytes>` : JSON.stringify(chunk);

const writeChunks = async (request) => {
  for (const chunk of chunks) {
    request.write(chunk);
    log(`sent ${describe(chunk)}`);
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  request.end();
  log('upload complete');
};

if (useHttp2) {
  const session = http2.connect(`https://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const request = session.request({ ':method': 'POST', ':path': '/stream/echo' }, { endStream: false });
  request.setEncoding('utf8');
  request.on('response', (headers) => log(`response status=${headers[':status']} alpn=${session.alpnProtocol}`));
  request.on('data', (chunk) => log(`received ${describe(chunk)}`));
  request.on('end', () => { log('response complete'); session.close(); });
  request.on('error', (error) => { console.error(error); session.destroy(); });
  await writeChunks(request);
} else {
  const request = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/stream/echo', headers: { 'Transfer-Encoding': 'chunked' } });
  request.on('response', (response) => {
    response.setEncoding('utf8');
    log(`response status=${response.statusCode} http=${response.httpVersion}`);
    response.on('data', (chunk) => log(`received ${describe(chunk)}`));
    response.on('end', () => log('response complete'));
  });
  request.on('error', console.error);
  await writeChunks(request);
}
