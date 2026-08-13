import { spawn } from "node:child_process";
import { createReadStream, existsSync, stat } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const root = normalize(join(import.meta.dirname, ".."));
const releaseAgentBin = join(
  root,
  "_build",
  "native",
  "release",
  "build",
  "cmd",
  "main",
  process.platform === "win32" ? "main.exe" : "main",
);
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

export function eventForAgentOutput(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return null;
  }
  if (event.type === "final_delta" && typeof event.text === "string") {
    return { type: "delta", text: event.text };
  }
  if (event.type === "final_started") {
    return { type: "status", message: "正在组织回答" };
  }
  if (event.type === "tool_started" && typeof event.name === "string") {
    return { type: "status", message: `正在使用 ${event.name}` };
  }
  if (event.type === "retrying") {
    return { type: "status", message: "连接波动，正在重试" };
  }
  if (event.type === "thinking_delta") {
    return { type: "status", message: "正在分析问题" };
  }
  return null;
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

async function runAgent(messages, emitEvent) {
  const configuredBin = process.env.MOONSAGE_AGENT_BIN;
  const builtBin = !configuredBin && existsSync(releaseAgentBin) ? releaseAgentBin : null;
  const executable = configuredBin || builtBin || "moon";
  const prompt = buildAgentPrompt(messages);
  const tempRoot = await mkdtemp(join(tmpdir(), "moonsage-agent-"));
  const inputFile = join(tempRoot, "prompt.txt");
  await writeFile(inputFile, prompt, "utf8");
  const args = configuredBin || builtBin
    ? ["ask", "--stream-json", "--input-file", inputFile]
    : ["run", "cmd/main", "--", "ask", "--stream-json", "--input-file", inputFile];
  try {
    return await new Promise((resolveResult) => {
      const child = spawn(executable, args, {
        cwd: root,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let answer = "";
      let errorMessage = "";
      let stderr = "";
      let pending = "";
      let outputBytes = 0;
      let settled = false;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolveResult(result);
      };
      const acceptLine = (line) => {
        if (!line.trim()) return;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          return;
        }
        if (event.type === "final_delta" && typeof event.text === "string") answer += event.text;
        if (event.type === "error" && typeof event.message === "string") errorMessage = event.message;
        const outgoing = eventForAgentOutput(line);
        if (outgoing) emitEvent(outgoing);
      };
      const timeout = setTimeout(() => {
        child.kill();
        finish({ error: `Agent 请求超过 ${Math.ceil(agentTimeoutMs / 1000)} 秒。` });
      }, agentTimeoutMs);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        outputBytes += Buffer.byteLength(chunk);
        if (outputBytes > 8 * 1024 * 1024) {
          child.kill();
          finish({ error: "Agent 输出超过 8 MB。" });
          return;
        }
        pending += chunk;
        const lines = pending.split(/\r?\n/);
        pending = lines.pop() ?? "";
        for (const line of lines) acceptLine(line);
      });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => {
        stderr = (stderr + chunk).slice(-16_384);
      });
      child.on("error", (error) => finish({ error: error.message }));
      child.on("close", () => {
        if (pending.trim()) acceptLine(pending);
        if (answer.trim()) finish({ answer });
        else finish({ error: errorMessage || stderr.trim() || "Agent 没有返回最终内容。" });
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

function beginEventStream(response) {
  response.writeHead(200, {
    "Content-Type": "application/x-ndjson; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Content-Type-Options": "nosniff",
  });
  response.flushHeaders();
}

function sendEvent(response, event) {
  if (!response.writableEnded) response.write(`${JSON.stringify(event)}\n`);
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
    beginEventStream(response);
    sendEvent(response, { type: "status", message: "正在启动 Agent" });
    let streamedAnswer = false;
    const result = await agentRunner(document.messages, (event) => {
      if (event.type === "delta") streamedAnswer = true;
      sendEvent(response, event);
    });
    if (result?.answer && !streamedAnswer) {
      sendEvent(response, { type: "delta", text: result.answer });
    }
    if (result?.error) sendEvent(response, { type: "error", message: result.error });
    else sendEvent(response, { type: "done" });
    response.end();
  } catch (error) {
    if (response.headersSent) {
      sendEvent(response, { type: "error", message: error.message });
      response.end();
    } else if (!response.writableEnded) {
      sendJson(response, 200, { error: error.message });
    }
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
