import { execFile, spawn } from "node:child_process";
import { createReadStream, existsSync, stat } from "node:fs";
import { lstat, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { basename, extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

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
const maxWorkspaceRequestBytes = 2 * 1024 * 1024;
const maxWorkspaceFileBytes = 1024 * 1024;
const maxWorkspaceFiles = 5000;
const execFileAsync = promisify(execFile);
const ignoredWorkspaceDirectories = new Set([".git", ".mooncakes", ".moonsage", "_build", "node_modules", "target"]);
const ignoredWorkspaceFiles = new Set([".env"]);
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

function readJsonBody(request, maxBytes = maxRequestBytes) {
  return new Promise((resolveBody, rejectBody) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        rejectBody(new Error(`请求体不能超过 ${Math.ceil(maxBytes / 1024)} KB。`));
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

export function resolveWorkspacePath(workspaceRoot, requestedPath) {
  if (typeof requestedPath !== "string" || requestedPath.includes("\0")) return null;
  const normalizedPath = requestedPath.replaceAll("\\", "/");
  if (normalizedPath === "" || normalizedPath.startsWith("/") || isAbsolute(normalizedPath)) return null;
  const segments = normalizedPath.split("/");
  if (segments.some((segment) => ignoredWorkspaceDirectories.has(segment))) return null;
  if (ignoredWorkspaceFiles.has(segments.at(-1))) return null;
  const path = resolve(workspaceRoot, normalizedPath);
  const rel = relative(workspaceRoot, path);
  if (rel === "" || rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) return null;
  return path;
}

async function verifiedWorkspaceFile(workspaceRoot, requestedPath) {
  const path = resolveWorkspacePath(workspaceRoot, requestedPath);
  if (!path) throw new Error("File path is outside the workspace.");
  const entry = await lstat(path);
  if (!entry.isFile() || entry.isSymbolicLink()) throw new Error("Only regular workspace files are supported.");
  const canonicalRoot = await realpath(workspaceRoot);
  const canonicalPath = await realpath(path);
  const rel = relative(canonicalRoot, canonicalPath);
  if (rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) {
    throw new Error("File path is outside the workspace.");
  }
  if (entry.size > maxWorkspaceFileBytes) throw new Error("Files larger than 1 MB cannot be edited here.");
  return { path, size: entry.size };
}

async function collectWorkspaceFiles(workspaceRoot) {
  const files = [];
  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (files.length >= maxWorkspaceFiles) return;
      if (entry.isSymbolicLink() || ignoredWorkspaceDirectories.has(entry.name) || ignoredWorkspaceFiles.has(entry.name)) continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) files.push(relative(workspaceRoot, path).split(sep).join("/"));
    }
  }
  await visit(workspaceRoot);
  return { files, truncated: files.length >= maxWorkspaceFiles };
}

async function runGit(workspaceRoot, args, acceptedExitCodes = [0]) {
  try {
    const result = await execFileAsync("git", args, {
      cwd: workspaceRoot,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 30_000,
      windowsHide: true,
    });
    return result.stdout;
  } catch (error) {
    if (acceptedExitCodes.includes(error.code)) return String(error.stdout || "");
    const detail = String(error.stderr || error.message || "").trim();
    throw new Error(detail || "Git command failed.");
  }
}

async function workspaceDiff(workspaceRoot, scope, requestedPath) {
  const args = ["diff", "--no-ext-diff", "--no-color"];
  if (scope === "staged") args.push("--cached");
  if (requestedPath) args.push("--", requestedPath);
  let diff = await runGit(workspaceRoot, args);
  if (scope === "staged") return diff;
  const status = await workspaceStatus(workspaceRoot);
  const untracked = status.changes.filter((change) => (
    change.untracked && (!requestedPath || change.path === requestedPath)
  ));
  for (const change of untracked) {
    diff += await runGit(
      workspaceRoot,
      ["diff", "--no-index", "--no-color", "--", "/dev/null", change.path],
      [0, 1],
    );
  }
  return diff;
}

export function parseGitStatus(output) {
  const fields = output.split("\0");
  const changes = [];
  for (let index = 0; index < fields.length; index += 1) {
    const record = fields[index];
    if (!record || record.length < 4) continue;
    const status = record.slice(0, 2);
    const path = record.slice(3);
    const indexStatus = status[0];
    const worktreeStatus = status[1];
    changes.push({
      path,
      index: indexStatus,
      worktree: worktreeStatus,
      staged: indexStatus !== " " && indexStatus !== "?",
      unstaged: worktreeStatus !== " " || status === "??",
      untracked: status === "??",
    });
    if (indexStatus === "R" || indexStatus === "C") index += 1;
  }
  return changes;
}

async function workspaceStatus(workspaceRoot) {
  const [branch, porcelain] = await Promise.all([
    runGit(workspaceRoot, ["branch", "--show-current"]),
    runGit(workspaceRoot, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
  ]);
  return { branch: branch.trim() || "detached HEAD", changes: parseGitStatus(porcelain) };
}

function queryPath(requestUrl, name) {
  return new URL(requestUrl, "http://localhost").searchParams.get(name) ?? "";
}

async function serveWorkspace(request, response, pathname, workspaceRoot) {
  try {
    if (pathname === "/api/workspace/tree" && request.method === "GET") {
      const tree = await collectWorkspaceFiles(workspaceRoot);
      sendJson(response, 200, { root: basename(workspaceRoot), ...tree });
      return;
    }
    if (pathname === "/api/workspace/file" && request.method === "GET") {
      const requestedPath = queryPath(request.url, "path");
      const file = await verifiedWorkspaceFile(workspaceRoot, requestedPath);
      const data = await readFile(file.path);
      if (data.includes(0)) throw new Error("Binary files cannot be edited here.");
      sendJson(response, 200, { path: requestedPath, content: data.toString("utf8") });
      return;
    }
    if (pathname === "/api/workspace/file" && request.method === "PUT") {
      const document = await readJsonBody(request, maxWorkspaceRequestBytes);
      if (typeof document?.path !== "string" || typeof document?.content !== "string") {
        throw new Error("Save requests require path and content.");
      }
      if (Buffer.byteLength(document.content) > maxWorkspaceFileBytes) {
        throw new Error("Files larger than 1 MB cannot be saved here.");
      }
      const file = await verifiedWorkspaceFile(workspaceRoot, document.path);
      await writeFile(file.path, document.content, "utf8");
      sendJson(response, 200, { path: document.path, saved: true });
      return;
    }
    if (pathname === "/api/workspace/git/status" && request.method === "GET") {
      sendJson(response, 200, await workspaceStatus(workspaceRoot));
      return;
    }
    if (pathname === "/api/workspace/git/diff" && request.method === "GET") {
      const scope = queryPath(request.url, "scope");
      if (!['working', 'staged'].includes(scope)) throw new Error("Invalid diff scope.");
      const requestedPath = queryPath(request.url, "path");
      if (requestedPath && !resolveWorkspacePath(workspaceRoot, requestedPath)) {
        throw new Error("File path is outside the workspace.");
      }
      const diff = await workspaceDiff(workspaceRoot, scope, requestedPath);
      sendJson(response, 200, { scope, path: requestedPath, diff });
      return;
    }
    if (pathname === "/api/workspace/git/stage" && request.method === "POST") {
      const document = await readJsonBody(request);
      const paths = Array.isArray(document?.paths) ? document.paths : [];
      if (paths.length === 0 || paths.some((path) => !resolveWorkspacePath(workspaceRoot, path))) {
        throw new Error("Select valid workspace files.");
      }
      await runGit(workspaceRoot, ["add", "--", ...paths]);
      sendJson(response, 200, await workspaceStatus(workspaceRoot));
      return;
    }
    if (pathname === "/api/workspace/git/unstage" && request.method === "POST") {
      const document = await readJsonBody(request);
      const paths = Array.isArray(document?.paths) ? document.paths : [];
      if (paths.length === 0 || paths.some((path) => !resolveWorkspacePath(workspaceRoot, path))) {
        throw new Error("Select valid workspace files.");
      }
      await runGit(workspaceRoot, ["reset", "--", ...paths]);
      sendJson(response, 200, await workspaceStatus(workspaceRoot));
      return;
    }
    if (pathname === "/api/workspace/git/commit" && request.method === "POST") {
      const document = await readJsonBody(request);
      const message = typeof document?.message === "string" ? document.message.trim() : "";
      if (!message || message.length > 200 || /[\r\n]/.test(message)) {
        throw new Error("Commit message must be a single line between 1 and 200 characters.");
      }
      const output = await runGit(workspaceRoot, ["commit", "-m", message]);
      sendJson(response, 200, { output: output.trim(), ...(await workspaceStatus(workspaceRoot)) });
      return;
    }
    sendJson(response, 405, { error: "Unsupported workspace operation." });
  } catch (error) {
    sendJson(response, error?.code === "ENOENT" ? 404 : 400, { error: error.message });
  }
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

export function serve({ listenPort = port, agentRunner = runAgent, workspaceRoot = root } = {}) {
  const server = createServer((request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === "/api/agent") {
      void serveAgent(request, response, agentRunner);
      return;
    }
    if (pathname.startsWith("/api/workspace/")) {
      void serveWorkspace(request, response, pathname, normalize(resolve(workspaceRoot)));
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
