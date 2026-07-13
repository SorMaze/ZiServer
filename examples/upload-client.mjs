import { createReadStream, statSync } from "node:fs";
import http from "node:http";
import http2 from "node:http2";

const useHttp2 = process.argv.includes("--http2");
const fileArg = process.argv.find((arg) => arg.startsWith("--file="));
const nameArg = process.argv.find((arg) => arg.startsWith("--name="));
const file = fileArg?.slice("--file=".length) || "README.md";
const uploadName = nameArg?.slice("--name=".length) || "upload.txt";
const size = statSync(file).size;

function sendBody(request) {
  return new Promise((resolve, reject) => {
    let response = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { response += chunk; });
    request.on("end", () => resolve(response));
    request.on("error", reject);
    createReadStream(file).on("error", reject).pipe(request);
  });
}

if (useHttp2) {
  const client = http2.connect("https://localhost:18443", { rejectUnauthorized: false });
  try {
    const request = client.request({
      ":method": "PUT",
      ":path": "/upload/stream",
      "content-type": "application/octet-stream",
      "content-length": String(size),
      "x-upload-filename": uploadName,
    });
    request.on("response", (headers) => console.log(`HTTP/2 status=${headers[":status"]}`));
    console.log(await sendBody(request));
  } finally {
    client.close();
  }
} else {
  const request = http.request({
    host: "127.0.0.1",
    port: 18080,
    method: "PUT",
    path: "/upload/stream",
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": size,
      "X-Upload-Filename": uploadName,
    },
  });
  request.on("response", async (response) => {
    response.setEncoding("utf8");
    let body = "";
    for await (const chunk of response) body += chunk;
    console.log(`HTTP/1.1 status=${response.statusCode}`);
    console.log(body);
  });
  createReadStream(file).pipe(request);
}
