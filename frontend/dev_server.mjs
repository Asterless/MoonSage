import { execFile, spawn } from "node:child_process";
import { createReadStream, existsSync, stat } from "node:fs";
import { appendFile, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { homedir, tmpdir } from "node:os";
import { basename, extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";

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
const ignoredWorkspaceDirectories = new Set([
  ".git",
  ".mooncakes",
  ".moonsage",
  ".cache",
  "_build",
  "_build.bak",
  "node_modules",
  "target",
]);
const ignoredWorkspaceFiles = new Set([".env"]);
const types = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
  ".json": "application/json; charset=utf-8",
};
const maxToolResultBytes = 4096;
const dataRoot = normalize(
  process.env.MOONSAGE_DATA_DIR ||
    (process.platform === "win32"
      ? join(process.env.LOCALAPPDATA || process.env.APPDATA || homedir(), "MoonSage")
      : process.platform === "darwin"
        ? join(homedir(), "Library", "Application Support", "MoonSage")
        : join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "moonsage")),
);
let activeDataRoot = dataRoot;
function workspaceRegistryPath() { return join(activeDataRoot, "workspaces.json"); }
function taskStorePath() { return join(activeDataRoot, "tasks"); }
const workspaceIdPattern = /^[a-z0-9-]{8,80}$/;
const taskIdPattern = /^[a-z0-9-]{8,80}$/;
const runningWriteTasks = new Map();

function isIgnoredWorkspaceDirectory(name) {
  const normalized = name.toLowerCase();
  return ignoredWorkspaceDirectories.has(normalized) || normalized.startsWith("_audit_ws_");
}

function isIgnoredWorkspacePath(requestedPath) {
  const segments = requestedPath.replaceAll("\\", "/").split("/").filter(Boolean);
  const filename = segments.at(-1)?.toLowerCase() ?? "";
  return segments.some(isIgnoredWorkspaceDirectory) || ignoredWorkspaceFiles.has(filename);
}

function emptyWorkspaceRegistry() {
  return { version: 1, workspaces: [] };
}

async function readWorkspaceRegistry() {
  try {
    const source = await readFile(workspaceRegistryPath(), "utf8");
    const document = JSON.parse(source);
    if (!document || document.version !== 1 || !Array.isArray(document.workspaces)) {
      return emptyWorkspaceRegistry();
    }
    const workspaces = document.workspaces.filter((workspace) => (
      workspace && workspace.id && workspace.root && workspace.name
    ));
    workspaces.sort((a, b) => String(b.last_used_at || "").localeCompare(String(a.last_used_at || "")));
    return {
      version: 1,
      workspaces,
    };
  } catch (error) {
    if (error.code === "ENOENT") return emptyWorkspaceRegistry();
    throw error;
  }
}

let workspaceRegistryWrite = Promise.resolve();
async function writeWorkspaceRegistry(document) {
  const next = workspaceRegistryWrite.catch(() => {}).then(async () => {
    await mkdir(activeDataRoot, { recursive: true });
    const target = workspaceRegistryPath();
    const temporary = `${target}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporary, JSON.stringify(document, null, 2) + "\n", "utf8");
    try {
      await rename(temporary, target);
    } finally {
      try {
        await rm(temporary, { force: true });
      } catch { /* the rename already removed it */ }
    }
  });
  workspaceRegistryWrite = next.catch(() => {});
  return next;
}

function publicWorkspace(workspace) {
  return {
    id: workspace.id,
    name: workspace.name,
    path: workspace.root,
    created_at: workspace.created_at,
    last_used_at: workspace.last_used_at,
  };
}

async function resolveRegisteredWorkspace(id, registry) {
  if (typeof id !== "string" || !workspaceIdPattern.test(id)) {
    throw new Error("Invalid workspace id.");
  }
  let record = registry ? await registry.get(id) : null;
  if (!registry) {
    const stored = await readWorkspaceRegistry();
    const workspace = stored.workspaces.find((entry) => entry.id === id);
    if (workspace) record = { ...publicWorkspace(workspace) };
  }
  if (!record) {
    const error = new Error("Workspace is not registered.");
    error.status = 404;
    throw error;
  }
  const canonical = await verifiedWorkspaceRoot(record.path || record.root);
  return { ...record, root: canonical };
}

async function registerWorkspace(requestedPath) {
  if (typeof requestedPath !== "string" || !requestedPath.trim()) {
    throw new Error("Workspace path is required.");
  }
  const canonical = await realpath(resolve(requestedPath));
  const entry = await lstat(canonical);
  if (!entry.isDirectory()) throw new Error("Workspace path must be a directory.");
  if (isIgnoredWorkspacePath(basename(canonical))) {
    throw new Error("Generated and hidden directories cannot be workspaces.");
  }
  const registry = await readWorkspaceRegistry();
  const existing = registry.workspaces.find((workspace) => workspace.root === canonical);
  if (existing) {
    existing.last_used_at = new Date().toISOString();
    await writeWorkspaceRegistry(registry);
    return existing;
  }
  const now = new Date().toISOString();
  const workspace = {
    id: randomUUID(),
    name: basename(canonical) || canonical,
    root: canonical,
    created_at: now,
    last_used_at: now,
  };
  registry.workspaces.push(workspace);
  await writeWorkspaceRegistry(registry);
  return workspace;
}

async function removeRegisteredWorkspace(id) {
  const registry = await readWorkspaceRegistry();
  const index = registry.workspaces.findIndex((workspace) => workspace.id === id);
  if (index < 0) {
    const error = new Error("Workspace is not registered.");
    error.status = 404;
    throw error;
  }
  const [removed] = registry.workspaces.splice(index, 1);
  await writeWorkspaceRegistry(registry);
  return removed;
}

async function pickWorkspaceDirectory() {
  if (process.platform === "win32") {
    const script = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){ $d.SelectedPath }";
    const result = await execFileAsync("powershell", ["-NoProfile", "-STA", "-NonInteractive", "-Command", script], {
      timeout: 120_000,
      windowsHide: true,
      maxBuffer: 16 * 1024,
      encoding: "utf8",
    });
    return result.stdout.trim();
  }
  if (process.platform === "darwin") {
    const result = await execFileAsync("osascript", ["-e", "POSIX path of (choose folder with prompt \"Choose a MoonSage workspace\")"], {
      timeout: 120_000,
      maxBuffer: 16 * 1024,
      encoding: "utf8",
    });
    return result.stdout.trim();
  }
  const result = await execFileAsync("zenity", ["--file-selection", "--directory", "--title=Choose a MoonSage workspace"], {
    timeout: 120_000,
    maxBuffer: 16 * 1024,
    encoding: "utf8",
  });
  return result.stdout.trim();
}

function taskPaths(id) {
  const directory = taskStorePath();
  return {
    meta: join(directory, `${id}.json`),
    events: join(directory, `${id}.jsonl`),
  };
}

async function readTask(id) {
  if (typeof id !== "string" || !taskIdPattern.test(id)) {
    throw new Error("Invalid task id.");
  }
  try {
    return JSON.parse(await readFile(taskPaths(id).meta, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") {
      const missing = new Error("Task is not found.");
      missing.status = 404;
      throw missing;
    }
    throw error;
  }
}

async function writeTask(task) {
  await mkdir(taskStorePath(), { recursive: true });
  await writeFile(taskPaths(task.id).meta, JSON.stringify(task, null, 2) + "\n", "utf8");
  return task;
}

async function appendTaskEvent(task, event) {
  await mkdir(taskStorePath(), { recursive: true });
  const record = { ...event, task_id: task.id, timestamp: new Date().toISOString() };
  await appendFile(taskPaths(task.id).events, JSON.stringify(record) + "\n", "utf8");
  if (event.type === "started") task.status = "running";
  if (event.type === "paused") task.status = "paused";
  if (event.type === "completed") task.status = "completed";
  if (event.type === "failed") task.status = "failed";
  if (event.type === "cancelled") task.status = "cancelled";
  task.updated_at = record.timestamp;
  await writeTask(task);
  return record;
}

async function readTaskEvents(id) {
  try {
    const source = await readFile(taskPaths(id).events, "utf8");
    return source.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

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
  // Static serving is a dev-only surface: allow only the frontend sources and
  // the built JS bundle. Everything else (.env, .git, .moonsage, mooncakes/,
  // ...) must never be reachable over HTTP.
  const allowed =
    rel === "frontend" ||
    rel.startsWith(`frontend${sep}`) ||
    rel === "_build" ||
    rel.startsWith(`_build${sep}js${sep}`);
  if (!allowed) return null;
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
  if (!event || typeof event !== "object" || Array.isArray(event)) return null;
  const validRound = Number.isInteger(event.round) && event.round >= 0;
  switch (event.type) {
    case "thinking_delta":
      return validRound && typeof event.text === "string" ? event : null;
    case "tool_started":
      return validRound &&
        typeof event.call_id === "string" &&
        typeof event.name === "string" &&
        typeof event.arguments === "string"
        ? event
        : null;
    case "tool_finished": {
      if (!validRound ||
        typeof event.call_id !== "string" ||
        typeof event.name !== "string" ||
        typeof event.status !== "string" ||
        typeof event.result !== "string") return null;
      let result = "";
      let resultBytes = 0;
      for (const character of event.result) {
        const characterBytes = Buffer.byteLength(character);
        if (resultBytes + characterBytes > maxToolResultBytes) break;
        result += character;
        resultBytes += characterBytes;
      }
      return result === event.result ? event : { ...event, result };
    }
    case "retrying":
      return Number.isInteger(event.attempt) && event.attempt >= 0 && typeof event.reason === "string"
        ? event
        : null;
    case "final_started":
      return event;
    case "final_delta":
      return typeof event.text === "string" ? event : null;
    case "warning":
    case "error":
      return typeof event.message === "string" ? event : null;
    default:
      return null;
  }
}

export function metaForConversation(messages) {
  const firstUser = messages.findIndex((message) => message.role === "user");
  const retained = firstUser >= 0 ? messages.slice(firstUser) : messages;
  return {
    type: "meta",
    history_truncated: retained.length > 40,
  };
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
  if (document.workspace_id !== undefined &&
    (typeof document.workspace_id !== "string" || !workspaceIdPattern.test(document.workspace_id))) {
    return "workspace_id 无效。";
  }
  return total <= 100_000 ? null : "会话内容过长，请新建会话后重试。";
}

function buildWorkspaceAgentPrompt(messages, context) {
  const latest = messages.at(-1)?.text ?? "";
  const instructions = context.permission === "read-only"
    ? "You may inspect the workspace but must not modify files."
    : "Work directly in the workspace using the available file tools. Explain planned changes before writing files.";
  return [
    "You are MoonSage operating as a workspace task agent.",
    `Workspace: ${context.workspaceRoot}`,
    `Task id: ${context.taskId || "ad-hoc"}`,
    `Permission: ${context.permission || "full-auto"}`,
    instructions,
    "Use relative paths in tool calls. Do not treat the chat transcript as the project; inspect the workspace when needed.",
    "",
    "TASK GOAL:",
    latest,
  ].join("\n");
}

async function runAgent(messages, emitEvent, signal, context = {}) {
  const configuredBin = process.env.MOONSAGE_AGENT_BIN;
  const builtBin = !configuredBin && existsSync(releaseAgentBin) ? releaseAgentBin : null;
  const executable = configuredBin || builtBin || "moon";
  const prompt = context.workspaceRoot
    ? buildWorkspaceAgentPrompt(messages, context)
    : buildAgentPrompt(messages);
  const tempRoot = await mkdtemp(join(tmpdir(), "moonsage-agent-"));
  const inputFile = join(tempRoot, "prompt.txt");
  await writeFile(inputFile, prompt, "utf8");
  const taskArgs = [
    "task",
    "--stream-json",
    "--workspace",
    context.workspaceRoot,
    "--input-file",
    inputFile,
    "--permission",
    context.permission || "full-auto",
  ];
  const askArgs = ["ask", "--stream-json", "--input-file", inputFile];
  const args = configuredBin || builtBin
    ? (context.workspaceRoot ? taskArgs : askArgs)
    : ["run", "cmd/main", "--", ...(context.workspaceRoot ? taskArgs : askArgs)];
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
        signal?.removeEventListener("abort", onAbort);
        resolveResult(result);
      };
      const onAbort = () => {
        killProcessTree(child);
        finish({ error: "请求已停止。" });
      };
      signal?.addEventListener("abort", onAbort, { once: true });
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
        killProcessTree(child);
        finish({ error: `Agent 请求超过 ${Math.ceil(agentTimeoutMs / 1000)} 秒。` });
      }, agentTimeoutMs);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        outputBytes += Buffer.byteLength(chunk);
        if (outputBytes > 8 * 1024 * 1024) {
          killProcessTree(child);
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
    let overLimit = false;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (overLimit) return;
      if (size > maxBytes) {
        overLimit = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (overLimit) {
        const error = new Error(`请求体不能超过 ${Math.ceil(maxBytes / 1024)} KB。`);
        error.status = 413;
        rejectBody(error);
        return;
      }
      try {
        resolveBody(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        rejectBody(new Error("请求体不是有效 JSON。"));
      }
    });
    request.on("error", rejectBody);
  });
}

const secureHeaders = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
};

function sendJson(response, status, document) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", ...secureHeaders });
  response.end(JSON.stringify(document));
}

// Accepts only loopback hosts (DNS rebinding protection) and, when a browser
// sends an Origin header, only same-origin pages.
export function isTrustedRequest(request, activePort) {
  const host = String(request.headers.host ?? "");
  const allowedHosts = new Set([
    `127.0.0.1:${activePort}`,
    `localhost:${activePort}`,
    `[::1]:${activePort}`,
  ]);
  if (!allowedHosts.has(host)) return false;
  const origin = request.headers.origin;
  if (origin !== undefined) {
    const allowedOrigins = new Set([
      `http://127.0.0.1:${activePort}`,
      `http://localhost:${activePort}`,
      `http://[::1]:${activePort}`,
    ]);
    if (!allowedOrigins.has(origin)) return false;
  }
  return true;
}

export function requireJsonContentType(request) {
  return String(request.headers["content-type"] ?? "")
    .toLowerCase()
    .startsWith("application/json");
}

// Terminates the child and, on Windows, its whole process tree (e.g. the
// `moon run` wrapper and the real agent executable) so timeouts and client
// disconnects never leave token-burning zombie agents behind.
export function killProcessTree(child) {
  if (child.pid === undefined) {
    try { child.kill(); } catch { /* already gone */ }
    return;
  }
  if (process.platform === "win32") {
    execFile("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true }, () => {
      try { child.kill(); } catch { /* already gone */ }
    });
  } else {
    try { process.kill(-child.pid, "SIGTERM"); } catch { /* no process group */ }
    try { child.kill("SIGTERM"); } catch { /* already gone */ }
  }
}

// Textareas normalize line endings to LF; restore the file's original style
// on save so Windows CRLF files do not turn into whole-file diffs.
export function normalizeLineEndings(content, style) {
  const normalized = content.replace(/\r\n/g, "\n");
  return style === "crlf" ? normalized.replace(/\n/g, "\r\n") : normalized;
}

export function resolveWorkspacePath(workspaceRoot, requestedPath) {
  if (typeof requestedPath !== "string" || requestedPath.includes("\0")) return null;
  const normalizedPath = requestedPath.replaceAll("\\", "/");
  if (normalizedPath === "" || normalizedPath.startsWith("/") || isAbsolute(normalizedPath)) return null;
  if (isIgnoredWorkspacePath(normalizedPath)) return null;
  const path = resolve(workspaceRoot, normalizedPath);
  const rel = relative(workspaceRoot, path);
  if (rel === "" || rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) return null;
  return path;
}

export function workspaceRelativePath(requestedPath) {
  if (typeof requestedPath !== "string" || requestedPath.includes("\0")) return null;
  const normalizedPath = requestedPath.replaceAll("\\", "/");
  if (
    normalizedPath === "" ||
    normalizedPath.startsWith("/") ||
    isAbsolute(normalizedPath) ||
    isIgnoredWorkspacePath(normalizedPath)
  ) return null;
  const segments = normalizedPath.split("/");
  if (segments.some((segment) => segment === "..")) return null;
  const cleaned = segments.filter((segment) => segment && segment !== ".").join("/");
  return cleaned || null;
}

function assertCanonicalWithin(rootPath, targetPath) {
  const rel = relative(rootPath, targetPath);
  if (rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) {
    throw new Error("File path is outside the workspace.");
  }
  const normalized = rel.split(sep).join("/");
  if (!normalized || isIgnoredWorkspacePath(normalized)) {
    throw new Error("File path is outside the workspace.");
  }
  return normalized;
}

/** Resolve and verify an existing workspace entry against its real path. */
export async function verifiedWorkspacePath(
  workspaceRoot,
  requestedPath,
  { kind = "file", maxBytes = maxWorkspaceFileBytes } = {},
) {
  const path = resolveWorkspacePath(workspaceRoot, requestedPath);
  if (!path) throw new Error("File path is outside the workspace.");
  const entry = await lstat(path);
  if (entry.isSymbolicLink()) throw new Error("Symbolic links are not supported in the workspace.");
  if (kind === "file" && !entry.isFile()) throw new Error("Only regular workspace files are supported.");
  if (kind === "directory" && !entry.isDirectory()) throw new Error("Workspace path must be a directory.");
  const canonicalRoot = await realpath(workspaceRoot);
  const canonicalPath = await realpath(path);
  const relativePath = assertCanonicalWithin(canonicalRoot, canonicalPath);
  if (kind === "file" && entry.size > maxBytes) {
    throw new Error("Files larger than 1 MB cannot be edited here.");
  }
  return { path, size: entry.size, relativePath };
}

async function verifyWorkspaceParents(workspaceRoot, normalizedPath) {
  let current = workspaceRoot;
  const segments = normalizedPath.split("/");
  for (const segment of segments.slice(0, -1)) {
    current = join(current, segment);
    try {
      const entry = await lstat(current);
      if (entry.isSymbolicLink()) {
        throw new Error("Symbolic links are not supported in the workspace.");
      }
      if (!entry.isDirectory()) {
        throw new Error("Workspace path must be a directory.");
      }
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
  }
}

/** Verify a Git path while allowing deleted paths to remain stageable. */
async function verifiedGitPath(workspaceRoot, requestedPath) {
  const normalized = workspaceRelativePath(requestedPath);
  if (!normalized) throw new Error("File path is outside the workspace.");
  await verifyWorkspaceParents(workspaceRoot, normalized);
  try {
    const entry = await lstat(resolve(workspaceRoot, normalized));
    if (entry.isSymbolicLink()) throw new Error("Symbolic links are not supported in the workspace.");
    await verifiedWorkspacePath(workspaceRoot, normalized, {
      kind: entry.isDirectory() ? "directory" : "file",
      maxBytes: Number.MAX_SAFE_INTEGER,
    });
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    // A deleted tracked file has no realpath to verify, but its lexical path
    // is still bounded by the workspace and can safely be passed to Git.
  }
  return normalized;
}

async function verifiedWorkspaceFile(workspaceRoot, requestedPath) {
  return verifiedWorkspacePath(workspaceRoot, requestedPath);
}

async function collectWorkspaceFiles(workspaceRoot) {
  const files = [];
  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (files.length >= maxWorkspaceFiles) return;
      const path = join(directory, entry.name);
      const requestedPath = relative(workspaceRoot, path).split(sep).join("/");
      if (entry.isSymbolicLink() || isIgnoredWorkspacePath(requestedPath)) continue;
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) files.push(requestedPath);
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
  const changes = parseGitStatus(porcelain).filter((change) => !isIgnoredWorkspacePath(change.path));
  return { branch: branch.trim() || "detached HEAD", changes };
}

function queryPath(requestUrl, name) {
  return new URL(requestUrl, "http://localhost").searchParams.get(name) ?? "";
}

async function verifiedWorkspaceRoot(workspaceRoot) {
  const candidate = resolve(workspaceRoot);
  const entry = await lstat(candidate);
  if (!entry.isDirectory()) throw new Error("Workspace path must be a directory.");
  return realpath(candidate);
}

async function serveWorkspace(request, response, pathname, workspaceRoot) {
  try {
    workspaceRoot = await verifiedWorkspaceRoot(workspaceRoot);
    if (
      (request.method === "POST" || request.method === "PUT") &&
      !requireJsonContentType(request)
    ) {
      sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
      return;
    }
    if (pathname === "/api/workspace/tree" && request.method === "GET") {
      const tree = await collectWorkspaceFiles(workspaceRoot);
      sendJson(response, 200, { root: basename(workspaceRoot), ...tree });
      return;
    }
    if (pathname === "/api/workspace/file" && request.method === "GET") {
      const requestedPath = queryPath(request.url, "path");
      const file = await verifiedWorkspaceFile(workspaceRoot, requestedPath);
      const data = await readFile(file.path);
      if (data.includes(0)) throw new Error("二进制文件不能在这里编辑。");
      let content;
      try {
        content = new TextDecoder("utf-8", { fatal: true }).decode(data);
      } catch {
        throw new Error("非 UTF-8 编码的文件不能在这里编辑。");
      }
      const line_endings = content.includes("\r\n") ? "crlf" : "lf";
      sendJson(response, 200, { path: requestedPath, content, line_endings });
      return;
    }
    if (pathname === "/api/workspace/file" && request.method === "PUT") {
      const document = await readJsonBody(request, maxWorkspaceRequestBytes);
      if (typeof document?.path !== "string" || typeof document?.content !== "string") {
        throw new Error("Save requests require path and content.");
      }
      if (Buffer.byteLength(document.content) > maxWorkspaceFileBytes) {
        throw new Error("大于 1 MB 的文件不能在这里保存。");
      }
      const style = document.line_endings === "crlf" ? "crlf" : "lf";
      const file = await verifiedWorkspaceFile(workspaceRoot, document.path);
      await writeFile(file.path, normalizeLineEndings(document.content, style), "utf8");
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
      const safePath = requestedPath ? await verifiedGitPath(workspaceRoot, requestedPath) : "";
      const diff = await workspaceDiff(workspaceRoot, scope, safePath);
      sendJson(response, 200, { scope, path: safePath, diff });
      return;
    }
    if (pathname === "/api/workspace/git/stage" && request.method === "POST") {
      const document = await readJsonBody(request);
      const paths = Array.isArray(document?.paths) ? document.paths : [];
      if (paths.length === 0) {
        throw new Error("Select valid workspace files.");
      }
      const safePaths = [];
      for (const path of paths) safePaths.push(await verifiedGitPath(workspaceRoot, path));
      await runGit(workspaceRoot, ["add", "--", ...safePaths]);
      sendJson(response, 200, await workspaceStatus(workspaceRoot));
      return;
    }
    if (pathname === "/api/workspace/git/unstage" && request.method === "POST") {
      const document = await readJsonBody(request);
      const paths = Array.isArray(document?.paths) ? document.paths : [];
      if (paths.length === 0) {
        throw new Error("Select valid workspace files.");
      }
      const safePaths = [];
      for (const path of paths) safePaths.push(await verifiedGitPath(workspaceRoot, path));
      await runGit(workspaceRoot, ["reset", "--", ...safePaths]);
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
    const status = error?.status === 413 ? 413 : error?.code === "ENOENT" ? 404 : 400;
    sendJson(response, status, { error: error.message });
  }
}

function beginEventStream(response) {
  response.writeHead(200, {
    "Content-Type": "application/x-ndjson; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    ...secureHeaders,
  });
  response.flushHeaders();
}

function sendEvent(response, event) {
  if (!response.writableEnded && !response.destroyed) response.write(`${JSON.stringify(event)}\n`);
}

async function serveAgent(request, response, agentRunner, registry, defaultWorkspaceRoot = "") {
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
    let workspace = document.workspace_id
      ? await resolveRegisteredWorkspace(document.workspace_id, registry)
      : null;
    if (!workspace && defaultWorkspaceRoot) {
      const registered = await registerWorkspace(defaultWorkspaceRoot);
      workspace = await resolveRegisteredWorkspace(registered.id, registry);
    }
    const context = workspace
      ? {
          workspaceId: workspace.id,
          workspaceRoot: workspace.root,
          permission: ["read-only", "controlled-write", "full-auto"].includes(document.permission)
            ? document.permission
            : "full-auto",
        }
      : {};
    beginEventStream(response);
    sendEvent(response, metaForConversation(document.messages));
    sendEvent(response, { type: "status", message: "正在启动 Agent" });
    const controller = new AbortController();
    response.on("close", () => {
      if (!response.writableEnded) controller.abort();
    });
    let finalStarted = false;
    let streamedAnswer = false;
    let streamedError = false;
    const result = await agentRunner(document.messages, (event) => {
      if (event.type === "final_started") finalStarted = true;
      if (event.type === "final_delta") streamedAnswer = true;
      if (event.type === "error") streamedError = true;
      sendEvent(response, event);
    }, controller.signal, context);
    if (!response.destroyed) {
      if (result?.answer && !streamedAnswer) {
        if (!finalStarted) sendEvent(response, { type: "final_started" });
        sendEvent(response, { type: "final_delta", text: result.answer });
      }
      if (result?.error) {
        if (!streamedError) sendEvent(response, { type: "error", message: result.error });
      } else {
        sendEvent(response, { type: "done" });
      }
    }
    try { response.end(); } catch { /* client already gone */ }
  } catch (error) {
    if (response.headersSent) {
      sendEvent(response, { type: "error", message: error.message });
      response.end();
    } else if (!response.writableEnded) {
      sendJson(response, 200, { error: error.message });
    }
  }
}

async function serveWorkspaceRegistry(request, response, pathname) {
  try {
    if (pathname === "/api/workspaces" && request.method === "GET") {
      const registry = await readWorkspaceRegistry();
      sendJson(response, 200, { workspaces: registry.workspaces.map(publicWorkspace) });
      return true;
    }
    if (pathname === "/api/workspaces" && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const document = await readJsonBody(request);
      const workspace = await registerWorkspace(document?.path);
      sendJson(response, 201, { workspace: publicWorkspace(workspace) });
      return true;
    }
    if (pathname === "/api/workspaces/pick" && request.method === "POST") {
      const selected = await pickWorkspaceDirectory();
      if (!selected) {
        sendJson(response, 200, { cancelled: true });
        return true;
      }
      const workspace = await registerWorkspace(selected);
      sendJson(response, 201, { workspace: publicWorkspace(workspace) });
      return true;
    }
    const match = pathname.match(/^\/api\/workspaces\/([^/]+)$/);
    if (match && request.method === "DELETE") {
      const id = decodeURIComponent(match[1]);
      const workspace = await removeRegisteredWorkspace(id);
      sendJson(response, 200, { removed: publicWorkspace(workspace) });
      return true;
    }
    const workspaceRoute = pathname.match(/^\/api\/workspaces\/([^/]+)(\/.*)$/);
    if (workspaceRoute) {
      const workspace = await resolveRegisteredWorkspace(decodeURIComponent(workspaceRoute[1]));
      const delegated = `/api/workspace${workspaceRoute[2]}`;
      await serveWorkspace(request, response, delegated, workspace.root);
      return true;
    }
    return false;
  } catch (error) {
    const status = error?.status === 404 ? 404 : error?.code === "ENOENT" ? 404 : 400;
    sendJson(response, status, { error: error.message });
    return true;
  }
}

function taskMessages(task) {
  return [{ role: "user", text: task.goal }];
}

async function runTask(task, emitEvent, signal, agentRunner) {
  const workspace = await resolveRegisteredWorkspace(task.workspace_id);
  const isWriter = task.permission !== "read-only";
  if (isWriter && runningWriteTasks.has(workspace.id)) {
    const error = new Error("该工作区已有写任务正在运行。请等待它完成后再试。");
    error.status = 409;
    throw error;
  }
  if (isWriter) runningWriteTasks.set(workspace.id, task.id);
  let log = Promise.resolve();
  let streamedAnswer = false;
  const record = (event) => {
    if (event.type === "final_delta") streamedAnswer = true;
    log = log.then(() => appendTaskEvent(task, event));
    emitEvent(event);
  };
  try {
    record({ type: "started", permission: task.permission });
    const result = await agentRunner(
      taskMessages(task),
      record,
      signal,
      {
        taskId: task.id,
        workspaceId: workspace.id,
        workspaceRoot: workspace.root,
        permission: task.permission,
      },
    );
    if (result?.answer && !streamedAnswer) {
      record({ type: "final_started" });
      record({ type: "final_delta", text: result.answer });
    }
    if (result?.error) {
      record({ type: "failed", message: result.error });
      return result;
    }
    record({ type: "completed" });
    return result || {};
  } catch (error) {
    record({ type: "failed", message: error.message });
    throw error;
  } finally {
    await log;
    if (isWriter && runningWriteTasks.get(workspace.id) === task.id) {
      runningWriteTasks.delete(workspace.id);
    }
  }
}

async function serveTaskRun(request, response, taskId, agentRunner) {
  try {
    if (request.method !== "POST") {
      sendJson(response, 405, { error: "仅支持 POST 请求。" });
      return;
    }
    const task = await readTask(taskId);
    if (task.status === "running") {
      sendJson(response, 409, { error: "任务已经在运行。" });
      return;
    }
    beginEventStream(response);
    const controller = new AbortController();
    response.on("close", () => {
      if (!response.writableEnded) controller.abort();
    });
    let streamedAnswer = false;
    const result = await runTask(task, (event) => {
      if (event.type === "final_delta") streamedAnswer = true;
      sendEvent(response, event);
    }, controller.signal, agentRunner);
    if (result?.answer && !streamedAnswer) sendEvent(response, { type: "final_delta", text: result.answer });
    if (!result?.error) sendEvent(response, { type: "done" });
    try { response.end(); } catch { /* client already gone */ }
  } catch (error) {
    if (response.headersSent) {
      sendEvent(response, { type: "error", message: error.message });
      try { response.end(); } catch { /* client already gone */ }
    } else {
      sendJson(response, error?.status === 409 ? 409 : error?.status === 404 ? 404 : 400, { error: error.message });
    }
  }
}

async function serveTasks(request, response, pathname, agentRunner) {
  try {
    if (pathname === "/api/tasks" && request.method === "GET") {
      const workspaceId = queryPath(request.url, "workspace_id");
      const tasks = [];
      try {
        const entries = await readdir(taskStorePath(), { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
          try {
            const task = JSON.parse(await readFile(join(taskStorePath(), entry.name), "utf8"));
            if (!workspaceId || task.workspace_id === workspaceId) tasks.push(task);
          } catch { /* ignore a partially written task */ }
        }
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      tasks.sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
      sendJson(response, 200, { tasks });
      return true;
    }
    if (pathname === "/api/tasks" && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const document = await readJsonBody(request);
      if (typeof document?.workspace_id !== "string" || typeof document?.goal !== "string") {
        throw new Error("workspace_id and goal are required.");
      }
      const workspace = await resolveRegisteredWorkspace(document.workspace_id);
      const goal = document.goal.trim();
      if (!goal || goal.length > 100_000) throw new Error("Task goal must be between 1 and 100000 characters.");
      const permission = ["read-only", "controlled-write", "full-auto"].includes(document.permission)
        ? document.permission
        : "full-auto";
      const now = new Date().toISOString();
      const task = {
        id: randomUUID(),
        workspace_id: workspace.id,
        goal,
        permission,
        status: "queued",
        created_at: now,
        updated_at: now,
      };
      await writeTask(task);
      await appendTaskEvent(task, { type: "created", goal, permission });
      sendJson(response, 201, { task });
      return true;
    }
    const detail = pathname.match(/^\/api\/tasks\/([^/]+)$/);
    if (detail && request.method === "GET") {
      const task = await readTask(decodeURIComponent(detail[1]));
      sendJson(response, 200, { task, events: await readTaskEvents(task.id) });
      return true;
    }
    const run = pathname.match(/^\/api\/tasks\/([^/]+)\/run$/);
    if (run) {
      await serveTaskRun(request, response, decodeURIComponent(run[1]), agentRunner);
      return true;
    }
    return false;
  } catch (error) {
    sendJson(response, error?.status === 404 ? 404 : error?.status === 409 ? 409 : 400, { error: error.message });
    return true;
  }
}

export function serve({
  listenPort = port,
  agentRunner = runAgent,
  workspaceRoot = root,
  workspaceDataDirectory,
} = {}) {
  if (workspaceDataDirectory) activeDataRoot = normalize(resolve(workspaceDataDirectory));
  let server;
  server = createServer((request, response) => {
    const address = server.address();
    const activePort = typeof address === "object" && address ? address.port : listenPort;
    if (!isTrustedRequest(request, activePort)) {
      response.writeHead(403, secureHeaders).end("Forbidden");
      return;
    }
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === "/api/agent") {
      void serveAgent(request, response, agentRunner);
      return;
    }
    if (pathname === "/api/workspaces" || pathname.startsWith("/api/workspaces/")) {
      void serveWorkspaceRegistry(request, response, pathname);
      return;
    }
    if (pathname === "/api/tasks" || pathname.startsWith("/api/tasks/")) {
      void serveTasks(request, response, pathname, agentRunner);
      return;
    }
    if (pathname.startsWith("/api/workspace/")) {
      void serveWorkspace(request, response, pathname, normalize(resolve(workspaceRoot)));
      return;
    }
    let path = resolveRequestPath(pathname);
    if (path === null) {
      response.writeHead(403, secureHeaders).end("Forbidden");
      return;
    }
    stat(path, (error, entry) => {
      if (!error && entry.isDirectory()) path = join(path, "index.html");
      stat(path, (fileError, file) => {
        if (fileError || !file.isFile()) {
          response.writeHead(404, secureHeaders).end("Not found");
          return;
        }
        response.writeHead(200, {
          "Content-Type": types[extname(path)] ?? "application/octet-stream",
          "Cache-Control": "no-cache",
          ...secureHeaders,
        });
        createReadStream(path).pipe(response);
      });
    });
  });
  server.listen(listenPort, "127.0.0.1", () => {
    const address = server.address();
    const activePort = typeof address === "object" && address ? address.port : listenPort;
    if (normalize(resolve(workspaceRoot)) === root) {
      void registerWorkspace(workspaceRoot).catch(() => {});
    }
    console.log(`MoonSage frontend: http://127.0.0.1:${activePort}/frontend/`);
  });
  return server;
}

const entry = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (entry === import.meta.url) serve();
