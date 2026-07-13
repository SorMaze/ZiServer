const encoder = new TextEncoder();
const decoder = new TextDecoder();
let activeController = null;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stamp = (start) => `${Math.round(performance.now() - start)}ms`;

async function readResponse(response, output, start) {
  output.textContent += `[${stamp(start)}] status=${response.status}\n`;
  const reader = response.body.getReader();
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    const decoded = decoder.decode(value, { stream: true });
    const display = decoded.length > 256 ? `${decoded.slice(0, 256)}…` : decoded;
    output.textContent += `[${stamp(start)}] recv ${value.byteLength}B: ${display}`;
  }
  output.textContent += `[${stamp(start)}] response complete\n`;
}

document.querySelector('#download').addEventListener('click', async () => {
  const output = document.querySelector('#download-log');
  output.textContent = '';
  activeController = new AbortController();
  const start = performance.now();
  try {
    const response = await fetch('/stream/demo', { cache: 'no-store', signal: activeController.signal });
    await readResponse(response, output, start);
  } catch (error) {
    output.textContent += `[${stamp(start)}] ${error.name}: ${error.message}\n`;
  }
});

document.querySelector('#upload').addEventListener('click', async () => {
  const output = document.querySelector('#upload-log');
  output.textContent = '';
  activeController = new AbortController();
  const start = performance.now();
  const body = new ReadableStream({
    async start(controller) {
      for (let index = 1; index <= 6; index += 1) {
        const chunk = `browser-chunk-${index}\n`;
        controller.enqueue(encoder.encode(chunk));
        output.textContent += `[${stamp(start)}] sent: ${chunk}`;
        await sleep(250);
      }
      controller.close();
      output.textContent += `[${stamp(start)}] upload complete\n`;
    },
  });
  try {
    const response = await fetch('/stream/echo', {
      method: 'POST',
      body,
      duplex: 'half',
      signal: activeController.signal,
    });
    await readResponse(response, output, start);
  } catch (error) {
    output.textContent += `[${stamp(start)}] ${error.name}: ${error.message}\n`;
  }
});

document.querySelector('#cancel').addEventListener('click', () => activeController?.abort());
