import { execFile } from "node:child_process";
import { createReadStream, stat } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const root = normalize(join(import.meta.dirname, ".."));
const port = Number(process.env.PORT ?? 8765);
const agentTimeoutMs = Number(process.env.MOONSAGE_AGENT_TIMEOUT_MS ?? 120_000);
const maxRequestBytes = 256 * 1024;
const types = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

export function resolveRequestPath(pathname) {
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  const path = resolve(root, `.${decoded}`);
  const rel = relative(root, path);
  if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  return path;
}

export function buildAgentPrompt(messages) {
  const firstUser = messages.findIndex((message) => message.role === "user");
  const conversation = (firstUser >= 0 ? messages.slice(firstUser) : messages).slice(-40);
  const latest = conversation.at(-1);
  const history = conversation.slice(0, -1).map(({ role, text }) => {
    const label = role === "assistant" ? "Assistant" : "User";
    return `${label}:\n${text}`;
  }).join("\n\n");
  const currentRequest = latest?.text ?? "";
  return [
    "Continue the conversation below and answer CURRENT USER REQUEST directly in the user's language.",
    "Conversation history provides context. The current user request is the task to perform.",
    "",
    "CONVERSATION HISTORY:",
    history || "(none)",
    "",
    "CURRENT USER REQUEST:",
    currentRequest,
  ].join("\n");
}

export function parseAgentEvents(output) {
  let answer = "";
  let error = "";
  for (const line of output.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type === "final_delta" && typeof event.text === "string") answer += event.text;
    if (event.type === "error" && typeof event.message === "string") error = event.message;
  }
  if (answer.trim()) return { answer };
  return { error: error || "Agent 没有返回最终内容。" };
}

function validateAgentRequest(document) {
  if (!document || typeof document !== "object" || !Array.isArray(document.messages)) {
    return "请求需要 messages 数组。";
  }
  if (document.messages.length === 0) {
    return "会话至少需要一条消息。";
  }
  let total = 0;
  for (const message of document.messages.slice(-40)) {
    if (!message || !["user", "assistant"].includes(message.role) || typeof message.text !== "string") {
      return "每条消息都需要有效的 role 和 text。";
    }
    total += message.text.length;
  }
  return total <= 100_000 ? null : "会话内容过长，请新建会话后重试。";
}

async function runAgent(messages) {
  const configuredBin = process.env.MOONSAGE_AGENT_BIN;
  const executable = configuredBin || "moon";
  const prompt = buildAgentPrompt(messages);
  const tempRoot = await mkdtemp(join(tmpdir(), "moonsage-agent-"));
  const inputFile = join(tempRoot, "prompt.txt");
  await writeFile(inputFile, prompt, "utf8");
  const args = configuredBin
    ? ["ask", "--stream-json", "--input-file", inputFile]
    : ["run", "cmd/main", "--", "ask", "--stream-json", "--input-file", inputFile];
  try {
    return await new Promise((resolveResult) => {
      execFile(executable, args, {
        cwd: root,
        encoding: "utf8",
        timeout: agentTimeoutMs,
        maxBuffer: 8 * 1024 * 1024,
        windowsHide: true,
      }, (error, stdout, stderr) => {
        const result = parseAgentEvents(stdout);
        if (result.answer) {
          resolveResult(result);
          return;
        }
        const reason = result.error || stderr.trim() || error?.message || "Agent 请求失败。";
        resolveResult({ error: reason });
      });
    });
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
}

function readJsonBody(request) {
  return new Promise((resolveBody, rejectBody) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxRequestBytes) {
        rejectBody(new Error("请求体不能超过 256 KB。"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        resolveBody(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        rejectBody(new Error("请求体不是有效 JSON。"));
      }
    });
    request.on("error", rejectBody);
  });
}

function sendJson(response, status, document) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(document));
}

async function serveAgent(request, response, agentRunner) {
  if (request.method !== "POST") {
    sendJson(response, 405, { error: "仅支持 POST 请求。" });
    return;
  }
  if (!request.headers["content-type"]?.toLowerCase().startsWith("application/json")) {
    sendJson(response, 415, { error: "请求需要 application/json。" });
    return;
  }
  try {
    const document = await readJsonBody(request);
    const invalid = validateAgentRequest(document);
    if (invalid) {
      sendJson(response, 200, { error: invalid });
      return;
    }
    sendJson(response, 200, await agentRunner(document.messages));
  } catch (error) {
    if (!response.writableEnded) sendJson(response, 200, { error: error.message });
  }
}

export function serve({ listenPort = port, agentRunner = runAgent } = {}) {
  const server = createServer((request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === "/api/agent") {
      void serveAgent(request, response, agentRunner);
      return;
    }
    let path = resolveRequestPath(pathname);
    if (path === null) {
      response.writeHead(403).end("Forbidden");
      return;
    }
    stat(path, (error, entry) => {
      if (!error && entry.isDirectory()) path = join(path, "index.html");
      stat(path, (fileError, file) => {
        if (fileError || !file.isFile()) {
          response.writeHead(404).end("Not found");
          return;
        }
        response.writeHead(200, { "Content-Type": types[extname(path)] ?? "application/octet-stream" });
        createReadStream(path).pipe(response);
      });
    });
  });
  server.listen(listenPort, "127.0.0.1", () => {
    const address = server.address();
    const activePort = typeof address === "object" && address ? address.port : listenPort;
    console.log(`MoonSage frontend: http://127.0.0.1:${activePort}/frontend/`);
  });
  return server;
}

const entry = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (entry === import.meta.url) serve();
