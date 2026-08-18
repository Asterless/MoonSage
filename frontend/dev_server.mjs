import { execFile, spawn } from "node:child_process";
import { createReadStream, existsSync, stat } from "node:fs";
import { appendFile, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { homedir, tmpdir } from "node:os";
import { basename, extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { createHash, randomUUID } from "node:crypto";
import {
  WorktreeError,
  WorktreeManager,
  migrateRegistry,
} from "./worktree_manager.mjs";

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
let activeWorktreeManager = null;
function workspaceRegistryPath() { return join(activeDataRoot, "workspaces.json"); }
function taskStorePath() { return join(activeDataRoot, "tasks"); }
function batchStorePath(dataDirectory = activeDataRoot) { return join(dataDirectory, "batches"); }
const workspaceIdPattern = /^[a-z0-9-]{8,80}$/;
const taskIdPattern = /^[a-z0-9-]{8,80}$/;
const batchIdPattern = /^[a-z0-9-]{8,100}$/;
const runningWriteTasks = new Map();
const runningTaskControllers = new Map();

function isIgnoredWorkspaceDirectory(name) {
  const normalized = name.toLowerCase();
  return ignoredWorkspaceDirectories.has(normalized) || normalized.startsWith("_audit_ws_");
}

function isIgnoredWorkspacePath(requestedPath) {
  const segments = requestedPath.replaceAll("\\", "/").split("/").filter(Boolean);
  const filename = segments.at(-1)?.toLowerCase() ?? "";
  return segments.some(isIgnoredWorkspaceDirectory) || ignoredWorkspaceFiles.has(filename);
}

function getWorktreeManager() {
  if (!activeWorktreeManager || activeWorktreeManager.dataDirectory !== normalize(resolve(activeDataRoot))) {
    activeWorktreeManager = new WorktreeManager({ dataDirectory: activeDataRoot });
  }
  return activeWorktreeManager;
}

function emptyWorkspaceRegistry() {
  return { version: 2, workspaces: [] };
}

async function readWorkspaceRegistry() {
  return getWorktreeManager().readRegistry();
}

let workspaceRegistryWrite = Promise.resolve();
async function writeWorkspaceRegistry(document) {
  return getWorktreeManager().writeRegistry(document);
}

function publicWorkspace(workspace) {
  return {
    id: workspace.id,
    name: workspace.name,
    path: workspace.root,
    root: workspace.root,
    kind: workspace.kind === "worktree" ? "worktree" : "local",
    managed: workspace.kind === "worktree",
    lifecycle: workspace.lifecycle || (workspace.kind === "worktree" ? "temporary" : "local"),
    cleanup: workspace.cleanup || (workspace.kind === "worktree" ? "prune" : "never"),
    repo_root: workspace.repo_root || workspace.repository_root || "",
    base_ref: workspace.base_ref || "",
    head: workspace.head || "",
    branch: workspace.branch || "",
    detached: workspace.detached === true,
    pinned: workspace.pinned === true,
    status: workspace.status || "ready",
    owner_task_id: workspace.owner_task_id || "",
    owner_session_id: workspace.owner_session_id || "",
    eligible_for_cleanup: workspace.eligible_for_cleanup === true,
    last_snapshot_id: workspace.last_snapshot_id || "",
    source_id: workspace.source_id || "",
    last_error: workspace.last_error || "",
    created_at: workspace.created_at,
    last_used_at: workspace.last_used_at,
  };
}

async function resolveRegisteredWorkspace(id, registry) {
  if (typeof id !== "string" || !workspaceIdPattern.test(id)) {
    throw new Error("Invalid workspace id.");
  }
  let record;
  if (registry) {
    record = await registry.get(id);
  } else {
    const stored = await readWorkspaceRegistry();
    record = stored.workspaces.find((entry) => entry.id === id);
  }
  if (!record) {
    const error = new Error("Workspace is not registered.");
    error.status = 404;
    throw error;
  }
  const canonical = await verifiedWorkspaceRoot(record.path || record.root);
  if (record.root !== canonical) {
    record.root = canonical;
    record.path = canonical;
  }
  record.last_used_at = new Date().toISOString();
  return { ...record, root: canonical, path: canonical };
}

async function registerWorkspace(requestedPath) {
  return getWorktreeManager().registerWorkspace({ path: requestedPath });
}

async function removeRegisteredWorkspace(id) {
  const manager = getWorktreeManager();
  const { record } = await manager.resolveRecord(id);
  if (record.kind === "worktree") return manager.removeWorktree(record);
  return manager.unregister(record);
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

async function workspaceUntrackedFiles(workspaceRoot) {
  const output = await runGit(workspaceRoot, ["ls-files", "--others", "--exclude-standard", "-z"]);
  return output.split("\0").filter(Boolean).filter((path) => !isIgnoredWorkspacePath(path));
}

async function saveWorkspaceSnapshot(workspaceRoot, workspaceId) {
  const snapshotRoot = join(activeDataRoot, "snapshots", `${workspaceId}-${Date.now()}-${randomUUID()}`);
  await mkdir(snapshotRoot, { recursive: true });
  const patch = await runGit(workspaceRoot, ["diff", "--binary", "HEAD"], [0, 128]);
  await writeFile(join(snapshotRoot, "changes.patch"), patch, "utf8");
  const files = await workspaceUntrackedFiles(workspaceRoot);
  await writeFile(join(snapshotRoot, "untracked.json"), JSON.stringify(files, null, 2) + "\n", "utf8");
  for (const relativePath of files) {
    const source = await verifiedWorkspacePath(workspaceRoot, relativePath, {
      kind: "file",
      maxBytes: maxWorkspaceFileBytes,
    });
    const target = join(snapshotRoot, "files", relativePath);
    await mkdir(join(target, ".."), { recursive: true });
    await copyFile(source.path, target);
  }
  return snapshotRoot;
}

async function transferWorkspaceChanges(sourceRoot, targetRoot, sourceId) {
  const targetStatus = await workspaceStatus(targetRoot);
  if (targetStatus.changes.length > 0) {
    const error = new Error("目标工作区存在未提交改动，无法安全移交。");
    error.status = 409;
    throw error;
  }
  const sourceStatus = await workspaceStatus(sourceRoot);
  if (sourceStatus.changes.length === 0) return { snapshot: "", applied: false };
  const snapshot = await saveWorkspaceSnapshot(sourceRoot, sourceId);
  const patch = await readFile(join(snapshot, "changes.patch"), "utf8");
  const patchPath = join(snapshot, "changes.patch");
  if (patch.trim()) {
    try {
      await execFileAsync("git", ["apply", "--3way", patchPath], {
        cwd: targetRoot,
        encoding: "utf8",
        timeout: 120_000,
        windowsHide: true,
        maxBuffer: 2 * 1024 * 1024,
      });
    } catch (error) {
      const conflict = new Error(String(error.stderr || error.message || "无法应用工作区改动。").trim());
      conflict.status = 409;
      conflict.snapshot = snapshot;
      throw conflict;
    }
  }
  const files = JSON.parse(await readFile(join(snapshot, "untracked.json"), "utf8"));
  for (const relativePath of files) {
    const source = join(snapshot, "files", relativePath);
    const target = resolve(targetRoot, relativePath);
    const safe = await verifiedWorkspacePath(targetRoot, relativePath, {
      kind: "file",
      maxBytes: maxWorkspaceFileBytes,
    }).catch(async (error) => {
      if (error?.code !== "ENOENT") throw error;
      const normalized = workspaceRelativePath(relativePath);
      if (!normalized) throw error;
      await verifyWorkspaceParents(targetRoot, normalized);
      return { path: target };
    });
    await mkdir(resolve(targetRoot, relativePath, ".."), { recursive: true });
    await copyFile(source, safe.path);
  }
  return { snapshot, applied: true };
}

async function enrichWorkspace(record) {
  const result = { ...record };
  try {
    const status = await workspaceStatus(record.root || record.path);
    result.head = status.head;
    result.branch = status.detached ? "" : status.branch;
    result.detached = status.detached;
    if (status.conflicts.length) {
      result.status = "conflicted";
    } else if (!["busy", "retained", "orphaned"].includes(result.status)) {
      result.status = "ready";
    }
  } catch {
    result.status = "orphaned";
  }
  return result;
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

function batchPaths(id, dataDirectory = activeDataRoot) {
  const directory = batchStorePath(dataDirectory);
  return {
    directory,
    meta: join(directory, `${id}.json`),
    events: join(directory, `${id}.jsonl`),
    control: join(directory, `${id}.control.json`),
    lock: join(directory, `${id}.lock`),
  };
}

function batchError(message, status = 400) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function requireBatchId(id) {
  if (typeof id !== "string" || !batchIdPattern.test(id)) {
    throw batchError("Invalid batch id.");
  }
  return id;
}

function stringList(value, name) {
  if (value === undefined || value === null || value === "") return [];
  const values = Array.isArray(value) ? value : [value];
  if (values.length > 100 || values.some((entry) => typeof entry !== "string")) {
    throw batchError(`${name} must be a string or an array of strings.`);
  }
  const normalized = values.map((entry) => entry.trim()).filter(Boolean);
  if (normalized.some((entry) => entry.length > 200 || /[\0\r\n]/.test(entry))) {
    throw batchError(`${name} contains an invalid value.`);
  }
  return [...new Set(normalized)];
}

function boundedInteger(value, fallback, minimum, maximum, name) {
  if (value === undefined || value === null || value === "") return fallback;
  const number = Number(value);
  if (!Number.isInteger(number) || number < minimum || number > maximum) {
    throw batchError(`${name} must be an integer between ${minimum} and ${maximum}.`);
  }
  return number;
}

function durationMilliseconds(value, fallback, minimum, maximum, name) {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < minimum || value > maximum) {
      throw batchError(`${name} is outside the supported range.`);
    }
    return Math.round(value);
  }
  if (typeof value !== "string") throw batchError(`${name} must be a duration.`);
  const match = value.trim().toLowerCase().match(/^(\d+)(ms|s|m|h|d)$/);
  if (!match) throw batchError(`${name} must use ms, s, m, h, or d.`);
  const units = { ms: 1, s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 };
  const milliseconds = Number(match[1]) * units[match[2]];
  if (!Number.isSafeInteger(milliseconds) || milliseconds < minimum || milliseconds > maximum) {
    throw batchError(`${name} is outside the supported range.`);
  }
  return milliseconds;
}

/** Validate and normalize the Web/CLI batch configuration persisted for the worker. */
export function normalizeBatchConfig(document = {}) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw batchError("Batch configuration must be an object.");
  }
  const source = document.config && typeof document.config === "object"
    ? { ...document, ...document.config }
    : document;
  const watch = source.watch === true || source.mode === "watch" || source.mode === "watching";
  return {
    watch,
    interval_ms: durationMilliseconds(
      source.interval_ms ?? source.interval,
      6 * 3_600_000,
      1000,
      30 * 86_400_000,
      "interval",
    ),
    limit: boundedInteger(source.limit, 0, 0, 1_000_000, "limit"),
    includes: stringList(source.includes ?? source.include, "include"),
    owners: stringList(source.owners ?? source.owner, "owner"),
    keywords: stringList(source.keywords ?? source.keyword, "keyword"),
    excludes: stringList(source.excludes ?? source.exclude, "exclude"),
    concurrency: boundedInteger(source.concurrency, 2, 1, 4, "concurrency"),
    max_prs: boundedInteger(source.max_prs ?? source.maxPrs, 10, 0, 1000, "max_prs"),
    package_timeout_ms: durationMilliseconds(
      source.package_timeout_ms ?? source.package_timeout ?? source.packageTimeout,
      20 * 60_000,
      1000,
      24 * 3_600_000,
      "package_timeout",
    ),
    max_calls: boundedInteger(source.max_calls ?? source.maxCalls, 80, 1, 10_000, "max_calls"),
    network_retries: boundedInteger(source.network_retries ?? source.networkRetries, 3, 0, 10, "network_retries"),
    policy_hash: typeof source.policy_hash === "string" && source.policy_hash.trim()
      ? source.policy_hash.trim().slice(0, 200)
      : "mode1-v1",
  };
}

function batchCounters(items) {
  const counters = {
    total: items.length,
    queued: 0,
    running: 0,
    created: 0,
    no_changes: 0,
    skipped: 0,
    failed: 0,
    cancelled: 0,
    verified_pending_publish: 0,
  };
  const active = new Set(["fetching", "auditing", "fixing", "verifying", "publishing"]);
  for (const item of items) {
    const status = String(item?.status || "queued");
    if (active.has(status)) counters.running += 1;
    else if (Object.hasOwn(counters, status)) counters[status] += 1;
  }
  return counters;
}

function publicBatch(batch) {
  const counts = {};
  for (const item of batch.items) {
    const status = String(item?.status || "queued");
    counts[status] = (counts[status] || 0) + 1;
  }
  const completed = ["created", "no_changes", "skipped", "failed", "cancelled"]
    .reduce((total, status) => total + (counts[status] || 0), 0);
  const createdAt = Number.isSafeInteger(batch.created_at_ms) && batch.created_at_ms > 0
    ? new Date(batch.created_at_ms).toISOString()
    : "";
  return {
    ...batch,
    mode: "batch-audit",
    total: batch.items.length,
    completed,
    failed: counts.failed || 0,
    created_prs: Number.isInteger(batch.pr_count)
      ? batch.pr_count
      : counts.created || 0,
    created_at: createdAt,
    counts,
    items: batch.items.map((item) => {
      const validation = item.validation && typeof item.validation === "object" ? item.validation : {};
      const validationSummary = [
        validation.check_passed ? "check passed" : "check failed",
        validation.build_passed ? "build passed" : "build failed",
        validation.test_passed ? "test passed" : "test failed",
      ].join(" · ");
      return {
        ...item,
        id: item.key,
        module: Array.isArray(item.module_names) ? item.module_names[0] || "" : "",
        validation_summary: validationSummary,
      };
    }),
  };
}

function redactBatchValue(value, key = "", depth = 0) {
  if (depth > 12) return "[truncated]";
  if (typeof value === "string") {
    if (/(token|secret|password|credential|api[_-]?key|authorization)/i.test(key)) return "[redacted]";
    const redacted = value
      .replace(/\b(?:ghp_[A-Za-z0-9_-]{12,}|github_pat_[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9_-]{12,})\b/g, "[redacted]")
      .replace(/\b(Bearer\s+)[A-Za-z0-9._~+\/-]{12,}/gi, "$1[redacted]");
    return redacted.length > 65_536 ? `${redacted.slice(0, 65_536)}\n[truncated]` : redacted;
  }
  if (Array.isArray(value)) return value.slice(0, 5000).map((entry) => redactBatchValue(entry, key, depth + 1));
  if (value && typeof value === "object") {
    const result = {};
    for (const [childKey, childValue] of Object.entries(value).slice(0, 5000)) {
      result[childKey] = redactBatchValue(childValue, childKey, depth + 1);
    }
    return result;
  }
  return value;
}

export async function readBatch(id, dataDirectory = activeDataRoot) {
  requireBatchId(id);
  try {
    const batch = JSON.parse(await readFile(batchPaths(id, dataDirectory).meta, "utf8"));
    if (!batch || batch.id !== id || !Array.isArray(batch.items)) {
      throw batchError("Batch metadata is invalid.");
    }
    return batch;
  } catch (error) {
    if (error.code === "ENOENT") throw batchError("Batch is not found.", 404);
    if (error instanceof SyntaxError) throw batchError("Batch metadata is invalid.");
    throw error;
  }
}

async function writeBatch(batch, dataDirectory = activeDataRoot) {
  const paths = batchPaths(requireBatchId(batch.id), dataDirectory);
  await mkdir(paths.directory, { recursive: true });
  const target = paths.meta;
  const temporary = `${target}.${process.pid}.${randomUUID()}.tmp`;
  const contents = JSON.stringify(redactBatchValue(batch), null, 2) + "\n";
  await writeFile(temporary, contents, "utf8");
  try {
    let replaced = false;
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        await rename(temporary, target);
        replaced = true;
        break;
      } catch (error) {
        if (!['EACCES', 'EPERM'].includes(error.code) || process.platform !== "win32") throw error;
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 5 * (attempt + 1)));
      }
    }
    // Windows scanners can briefly hold the destination open. Each new batch
    // has a unique id, so a direct fallback avoids failing batch creation.
    if (!replaced) await writeFile(target, contents, "utf8");
  } finally {
    try { await rm(temporary, { force: true }); } catch { /* rename removed it */ }
  }
  return batch;
}

export async function readBatchEvents(id, dataDirectory = activeDataRoot) {
  requireBatchId(id);
  try {
    const source = await readFile(batchPaths(id, dataDirectory).events, "utf8");
    const events = [];
    for (const line of source.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try { events.push(JSON.parse(line)); } catch { /* ignore a partial final line */ }
    }
    return events;
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
      let forcedResult = null;
      let timeout = null;
      let terminationTimeout = null;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        if (terminationTimeout) clearTimeout(terminationTimeout);
        signal?.removeEventListener("abort", onAbort);
        resolveResult(result);
      };
      const stopChild = (result) => {
        if (settled || forcedResult) return;
        forcedResult = result;
        killProcessTree(child);
        // Wait for the process tree to exit before the caller snapshots and
        // releases its worktree. Keep a bounded fallback for broken children.
        terminationTimeout = setTimeout(() => finish(result), 5_000);
      };
      const onAbort = () => stopChild({ cancelled: true });
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
      timeout = setTimeout(() => {
        stopChild({ error: `Agent 请求超过 ${Math.ceil(agentTimeoutMs / 1000)} 秒。` });
      }, agentTimeoutMs);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        outputBytes += Buffer.byteLength(chunk);
        if (outputBytes > 8 * 1024 * 1024) {
          stopChild({ error: "Agent 输出超过 8 MB。" });
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
      child.on("error", (error) => finish(forcedResult || { error: error.message }));
      child.on("close", () => {
        if (pending.trim()) acceptLine(pending);
        if (forcedResult) finish(forcedResult);
        else if (answer.trim()) finish({ answer });
        else finish({ error: errorMessage || stderr.trim() || "Agent 没有返回最终内容。" });
      });
      if (signal?.aborted) onAbort();
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
    const exitCode = Number(error.code);
    if (acceptedExitCodes.includes(exitCode) || acceptedExitCodes.includes(error.code)) {
      return String(error.stdout || "");
    }
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
    let path = record.slice(3);
    const indexStatus = status[0];
    const worktreeStatus = status[1];
    const conflicted = indexStatus === "U" || worktreeStatus === "U" || status === "AA" || status === "DD";
    const rename = indexStatus === "R" || worktreeStatus === "R";
    const copy = indexStatus === "C" || worktreeStatus === "C";
    let oldPath = "";
    if (rename || copy) {
      const separator = path.indexOf("\t");
      if (separator >= 0) {
        oldPath = path.slice(0, separator);
        path = path.slice(separator + 1);
      } else if (fields[index + 1]) {
        // `git status --porcelain=v1 -z` emits the old path as the next
        // NUL-delimited field for renames and copies.
        oldPath = fields[index + 1];
        index += 1;
      }
    }
    changes.push({
      path,
      old_path: oldPath,
      index: indexStatus,
      worktree: worktreeStatus,
      staged: indexStatus !== " " && indexStatus !== "?",
      unstaged: worktreeStatus !== " " || status === "??",
      untracked: status === "??",
      conflicted,
      rename,
      copy,
    });
  }
  return changes;
}

export async function workspaceStatus(workspaceRoot) {
  const [branch, porcelain, head, upstream] = await Promise.all([
    runGit(workspaceRoot, ["branch", "--show-current"]),
    runGit(workspaceRoot, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
    runGit(workspaceRoot, ["rev-parse", "--verify", "HEAD"], [0, 128]),
    runGit(workspaceRoot, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], [0, 128]),
  ]);
  const changes = parseGitStatus(porcelain).filter((change) => !isIgnoredWorkspacePath(change.path));
  let ahead = 0;
  let behind = 0;
  if (upstream.trim() && head.trim()) {
    const counts = await runGit(
      workspaceRoot,
      ["rev-list", "--left-right", "--count", `HEAD...${upstream.trim()}`],
      [0, 128],
    );
    const parts = counts.trim().split(/\s+/).map(Number);
    if (parts.length >= 2 && parts.every(Number.isFinite)) {
      ahead = parts[0];
      behind = parts[1];
    }
  }
  const renames = changes
    .filter((change) => change.rename || change.copy)
    .map((change) => ({ path: change.path, old_path: change.old_path || "", kind: change.rename ? "rename" : "copy" }));
  const conflicts = changes.filter((change) => change.conflicted).map((change) => change.path);
  const revision = createHash("sha256")
    .update(`${head.trim()}\0${porcelain}`)
    .digest("hex");
  return {
    branch: branch.trim() || "detached HEAD",
    head: head.trim(),
    detached: branch.trim() === "",
    upstream: upstream.trim(),
    ahead,
    behind,
    revision,
    conflicts,
    renames,
    changes,
  };
}

async function fileRevision(file) {
  const data = await readFile(file.path);
  const entry = await lstat(file.path);
  return {
    revision: createHash("sha256").update(data).digest("hex"),
    size: data.byteLength,
    mtime_ms: Number(entry.mtimeMs || 0),
  };
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
      const revision = await fileRevision(file);
      sendJson(response, 200, { path: requestedPath, content, line_endings, ...revision });
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
      if (document.expected_revision !== undefined) {
        if (typeof document.expected_revision !== "string" || document.expected_revision.length > 128) {
          const error = new Error("expected_revision 无效。");
          error.status = 400;
          throw error;
        }
        const current = await fileRevision(file);
        if (current.revision !== document.expected_revision) {
          const error = new Error("文件已被外部修改，请刷新后重试。");
          error.status = 409;
          error.current_revision = current.revision;
          throw error;
        }
      }
      await writeFile(file.path, normalizeLineEndings(document.content, style), "utf8");
      sendJson(response, 200, { path: document.path, saved: true, ...(await fileRevision(file)) });
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
    const status = error?.status === 413 ? 413 : error?.status === 409 ? 409 : error?.code === "ENOENT" ? 404 : 400;
    sendJson(response, status, { error: error.message, ...(error?.current_revision ? { current_revision: error.current_revision } : {}) });
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
      const workspaces = await Promise.all(registry.workspaces.map(async (workspace) => {
        const enriched = workspace.kind === "worktree" ? await enrichWorkspace(workspace) : workspace;
        return publicWorkspace(enriched);
      }));
      sendJson(response, 200, { workspaces });
      return true;
    }
    if (pathname === "/api/workspaces" && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const document = await readJsonBody(request);
      const workspace = await getWorktreeManager().registerWorkspace({
        path: document?.path,
        name: document?.name,
      });
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
    const worktreeCreate = pathname.match(/^\/api\/workspaces\/([^/]+)\/worktree$/);
    if (worktreeCreate && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const sourceId = decodeURIComponent(worktreeCreate[1]);
      const document = await readJsonBody(request);
      const manager = getWorktreeManager();
      const source = await resolveRegisteredWorkspace(sourceId);
      const branch = typeof document?.branch === "string" ? document.branch.trim() : "";
      const record = await manager.createWorktree({
        workspaceId: sourceId,
        baseRef: typeof document?.base_ref === "string" && document.base_ref.trim()
          ? document.base_ref.trim()
          : "HEAD",
        branch,
        detached: !branch,
        name: typeof document?.name === "string" ? document.name : undefined,
        lifecycle: document?.lifecycle === "permanent" ? "permanent" : "temporary",
        ownerTaskId: typeof document?.task_id === "string" ? document.task_id : "",
        ownerSessionId: typeof document?.session_id === "string" ? document.session_id : "",
        copyIgnored: document?.copy_ignored !== false,
        includeMaxBytes: Number.isSafeInteger(document?.include_max_bytes)
          ? document.include_max_bytes
          : undefined,
        includeMaxTotalBytes: Number.isSafeInteger(document?.include_max_total_bytes)
          ? document.include_max_total_bytes
          : undefined,
        includeMaxFiles: Number.isSafeInteger(document?.include_max_files)
          ? document.include_max_files
          : undefined,
      });
      try {
        if (document?.include_dirty === true) {
          const snapshot = await manager.createSnapshot(source, { reason: "worktree_create" });
          const moved = await manager.restoreSnapshot(snapshot, record);
          record.last_snapshot_id = snapshot.id;
          record.snapshot = snapshot.path;
          record.applied = moved.applied;
          await manager.updateRecord(record.id, {
            last_snapshot_id: snapshot.id,
            status: "ready",
          });
        }
      } catch (error) {
        await manager.removeWorktree(record, { force: true }).catch(() => {});
        throw error;
      }
      sendJson(response, 201, { workspace: publicWorkspace(await enrichWorkspace(record)) });
      return true;
    }
    const prune = pathname === "/api/workspaces/prune";
    if (prune && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const document = await readJsonBody(request);
      const result = await getWorktreeManager().prune({
        limit: Number.isInteger(document?.limit) ? document.limit : 15,
        maxAgeMs: Number.isInteger(document?.max_age_ms) ? document.max_age_ms : 0,
        force: document?.force === true,
      });
      sendJson(response, 200, result);
      return true;
    }
    const match = pathname.match(/^\/api\/workspaces\/([^/]+)$/);
    if (match && request.method === "GET") {
      const workspace = await resolveRegisteredWorkspace(decodeURIComponent(match[1]));
      sendJson(response, 200, { workspace: publicWorkspace(await enrichWorkspace(workspace)) });
      return true;
    }
    if (match && request.method === "DELETE") {
      const id = decodeURIComponent(match[1]);
      const workspace = await removeRegisteredWorkspace(id);
      sendJson(response, 200, { removed: publicWorkspace(workspace) });
      return true;
    }
    const action = pathname.match(/^\/api\/workspaces\/([^/]+)\/(handoff|branch|pin|restore)$/);
    if (action && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "写操作需要 application/json 请求。" });
        return true;
      }
      const id = decodeURIComponent(action[1]);
      const manager = getWorktreeManager();
      const { record } = await manager.resolveRecord(id);
      const document = await readJsonBody(request);
      if (action[2] === "pin") {
        const updated = await manager.pin(record, document?.pinned !== false);
        sendJson(response, 200, { workspace: publicWorkspace(updated) });
        return true;
      }
      if (action[2] === "branch") {
        const updated = await manager.createBranch(record, document?.name || document?.branch || "");
        sendJson(response, 200, { workspace: publicWorkspace(await enrichWorkspace(updated)) });
        return true;
      }
      if (action[2] === "restore") {
        const snapshotId = typeof document?.snapshot_id === "string" ? document.snapshot_id.trim() : "";
        if (!snapshotId) throw Object.assign(new Error("snapshot_id is required."), { status: 400 });
        const restored = await manager.restoreSnapshot(
          join(activeDataRoot, "snapshots", snapshotId),
          record,
          {
            expected_revision: typeof document?.expected_revision === "string" ? document.expected_revision : "",
            expected_head: typeof document?.expected_head === "string" ? document.expected_head : "",
          },
        );
        const updated = await manager.updateRecord(record, {
          status: "ready",
          last_snapshot_id: snapshotId,
          eligible_for_cleanup: false,
        });
        sendJson(response, 200, { workspace: publicWorkspace(await enrichWorkspace(updated)), snapshot: restored });
        return true;
      }
      const targetId = typeof document?.target_workspace_id === "string"
        ? document.target_workspace_id
        : typeof document?.target_id === "string" ? document.target_id : "";
      if (!targetId) throw Object.assign(new Error("target_workspace_id is required."), { status: 400 });
      const transfer = await manager.handoff(record, targetId, {
        expected_revision: typeof document?.expected_revision === "string" ? document.expected_revision : "",
        target_expected_revision: typeof document?.target_expected_revision === "string"
          ? document.target_expected_revision
          : "",
        target_expected_head: typeof document?.target_expected_head === "string"
          ? document.target_expected_head
          : "",
      });
      const updatedTarget = transfer.target;
      sendJson(response, 200, {
        workspace: publicWorkspace(await enrichWorkspace(updatedTarget)),
        snapshot: transfer.snapshot?.path || transfer.snapshot?.id || "",
        snapshot_id: transfer.snapshot?.id || "",
        applied: transfer.applied === true,
      });
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
    const status = error?.status ||
      (error?.code === "NOT_FOUND" || error?.code === "ENOENT" ? 404 :
        [
          "CONFLICT", "LEASED", "DIRTY", "PROTECTED", "GIT_ERROR", "BRANCH_IN_USE",
          "HANDOFF_CONFLICT", "SNAPSHOT_LIMIT", "SNAPSHOT_UNSAFE", "INVALID_SNAPSHOT",
        ].includes(error?.code) ? 409 : 400);
    sendJson(response, status, {
      error: error.message,
      code: error.code || "WORKSPACE_ERROR",
      ...(error.details && typeof error.details === "object" ? error.details : {}),
    });
    return true;
  }
}

function taskMessages(task) {
  return [{ role: "user", text: task.goal }];
}

async function acquireTaskWorkspace(task) {
  const base = await resolveRegisteredWorkspace(task.workspace_id);
  const manager = getWorktreeManager();
  const wantsManaged = task.workspace_mode === "managed" && task.permission !== "read-only";
  if (!wantsManaged) {
    task.execution_workspace_id = base.id;
    task.execution_workspace_path = base.root;
    return { workspace: base, lease: null };
  }
  let execution = null;
  let lease = null;
  let created = false;
  if (task.execution_workspace_id) {
    try {
      execution = await resolveRegisteredWorkspace(task.execution_workspace_id);
      if (execution.kind !== "worktree") execution = null;
    } catch {
      execution = null;
    }
  }
  if (!execution) {
    try {
      execution = await manager.createWorktree({
        workspaceId: base.id,
        baseRef: "HEAD",
        detached: true,
        lifecycle: "temporary",
        ownerTaskId: task.id,
        ownerSessionId: task.session_id || "",
      });
      created = true;
    } catch (error) {
      // Non-Git directories remain supported as Local checkouts, matching
      // Codex's direct-directory behavior for projects without Git metadata.
      if (error?.code !== "GIT_ERROR" || !/not a git repository|not a git work tree/i.test(error.message)) {
        throw error;
      }
      task.workspace_mode = "local";
      task.execution_workspace_id = base.id;
      task.execution_workspace_path = base.root;
      return { workspace: base, lease: null };
    }
    task.execution_workspace_id = execution.id;
  }
  try {
    lease = await manager.acquireLease(execution, { owner: `task:${task.id}` });
    await manager.updateRecord(execution, {
      owner_task_id: task.id,
      owner_session_id: task.session_id || "",
      status: "busy",
      eligible_for_cleanup: false,
    });
  } catch (error) {
    if (lease) await manager.releaseLease(execution, lease.token).catch(() => {});
    if (created) {
      // A newly allocated checkout is an implementation detail until its
      // lease and busy state are durable. Roll it back if setup cannot finish.
      await manager.removeWorktree(execution, { allowDirty: false }).catch(() => {});
      task.execution_workspace_id = "";
    }
    throw error;
  }
  task.execution_workspace_path = execution.root;
  return { workspace: { ...execution, root: execution.root }, lease };
}

async function releaseTaskWorkspace(task, lease, outcome = "success") {
  if (!lease || !task.execution_workspace_id) return;
  const manager = getWorktreeManager();
  const failed = outcome !== "success";
  let ownsLease = false;
  try {
    // Renewing first proves that this task still owns the lease. Never use a
    // force release here: an expired lease may already belong to another
    // process, and the old task must not delete or rewrite that owner's state.
    await manager.renewLease(task.execution_workspace_id, lease.token);
    ownsLease = true;
    let snapshotId = "";
    if (failed) {
      try {
        const snapshot = await manager.createSnapshot(task.execution_workspace_id, {
          reason: outcome === "cancelled" ? "task_cancelled" : "task_failed",
        });
        snapshotId = snapshot.id;
        task.snapshot_id = snapshot.id;
        task.snapshot_path = snapshot.path;
      } catch {
        // Preserve the worktree even if snapshot creation itself fails.
      }
    }
    await manager.updateRecord(task.execution_workspace_id, {
      status: failed ? "retained" : "ready",
      // Failed/cancelled worktrees and their snapshots must be explicitly
      // archived before they can ever be removed.
      eligible_for_cleanup: !failed,
      owner_task_id: task.id,
      owner_session_id: task.session_id || "",
      last_snapshot_id: snapshotId,
    });
    await writeTask(task);
  } catch {
    // The task result is already persisted; recovery will reconcile a stale
    // lease and orphaned worktree on the next server start.
  } finally {
    if (ownsLease) {
      await manager.releaseLease(task.execution_workspace_id, lease.token).catch(() => {});
    }
  }
}

async function runTask(task, emitEvent, signal, agentRunner) {
  let acquired;
  try {
    acquired = await acquireTaskWorkspace(task);
  } catch (error) {
    task.status = "failed";
    task.error = error.message;
    await writeTask(task).catch(() => {});
    throw error;
  }
  const workspace = acquired.workspace;
  const lease = acquired.lease;
  try {
    await writeTask(task);
  } catch (error) {
    await releaseTaskWorkspace(task, lease, "failed");
    throw error;
  }
  const isWriter = task.permission !== "read-only";
  if (isWriter && !lease && runningWriteTasks.has(workspace.id)) {
    const error = new Error("该工作区已有写任务正在运行。请等待它完成后再试。");
    error.status = 409;
    throw error;
  }
  if (isWriter && !lease) runningWriteTasks.set(workspace.id, task.id);
  let log = Promise.resolve();
  let streamedAnswer = false;
  let heartbeat = null;
  if (lease) {
    heartbeat = setInterval(() => {
      void getWorktreeManager().renewLease(task.execution_workspace_id, lease.token).catch(() => {});
    }, 5 * 60 * 1000);
  }
  const record = (event) => {
    if (event.type === "final_delta") streamedAnswer = true;
    log = log.then(() => appendTaskEvent(task, event));
    emitEvent(event);
  };
  try {
    record({
      type: "workspace_bound",
      workspace_id: workspace.id,
      workspace_mode: task.workspace_mode || "local",
      execution_workspace_id: task.execution_workspace_id || workspace.id,
    });
    record({ type: "started", permission: task.permission });
    const result = await agentRunner(
      taskMessages(task),
      record,
      signal,
      {
        taskId: task.id,
        workspaceId: workspace.id,
        workspaceRoot: workspace.root,
        workspaceMode: task.workspace_mode || "local",
        sessionId: task.session_id || "",
        permission: task.permission,
      },
    );
    if (result?.answer && !streamedAnswer) {
      record({ type: "final_started" });
      record({ type: "final_delta", text: result.answer });
    }
    if (result?.cancelled || signal.aborted) {
      task.cancel_requested = true;
      task.cancel_requested_at = task.cancel_requested_at || new Date().toISOString();
      record({ type: "cancelled", reason: "任务已取消" });
      await releaseTaskWorkspace(task, lease, "cancelled");
      return { cancelled: true };
    }
    if (result?.error) {
      record({ type: "failed", message: result.error });
      await releaseTaskWorkspace(task, lease, "failed");
      return result;
    }
    record({ type: "completed" });
    await releaseTaskWorkspace(task, lease, "success");
    return result || {};
  } catch (error) {
    if (signal.aborted) {
      task.cancel_requested = true;
      task.cancel_requested_at = task.cancel_requested_at || new Date().toISOString();
      record({ type: "cancelled", reason: "任务已取消" });
    } else {
      record({ type: "failed", message: error.message });
    }
    await releaseTaskWorkspace(task, lease, signal.aborted ? "cancelled" : "failed");
    if (signal.aborted) return { cancelled: true };
    throw error;
  } finally {
    if (heartbeat) clearInterval(heartbeat);
    await log;
    if (isWriter && !lease && runningWriteTasks.get(workspace.id) === task.id) {
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
    runningTaskControllers.set(task.id, controller);
    response.on("close", () => {
      if (!response.writableEnded) controller.abort();
    });
    let streamedAnswer = false;
    const result = await runTask(task, (event) => {
      if (event.type === "final_delta") streamedAnswer = true;
      sendEvent(response, event);
    }, controller.signal, agentRunner);
    runningTaskControllers.delete(task.id);
    if (result?.answer && !streamedAnswer) sendEvent(response, { type: "final_delta", text: result.answer });
    if (!result?.error && !result?.cancelled) sendEvent(response, { type: "done" });
    try { response.end(); } catch { /* client already gone */ }
  } catch (error) {
    runningTaskControllers.delete(taskId);
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
      const workspaceMode = ["local", "managed"].includes(document.workspace_mode)
        ? document.workspace_mode
        : permission === "read-only" ? "local" : "managed";
      const now = new Date().toISOString();
      const task = {
        id: randomUUID(),
        workspace_id: workspace.id,
        session_id: typeof document.session_id === "string" ? document.session_id.slice(0, 200) : "",
        workspace_mode: workspaceMode,
        execution_workspace_id: "",
        execution_workspace_path: "",
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
    const cancel = pathname.match(/^\/api\/tasks\/([^/]+)\/cancel$/);
    if (cancel && request.method === "POST") {
      const id = decodeURIComponent(cancel[1]);
      const task = await readTask(id);
      const controller = runningTaskControllers.get(id);
      if (!controller) {
        if (["completed", "failed", "cancelled"].includes(task.status)) {
          sendJson(response, 200, { task });
        } else {
          sendJson(response, 409, { error: "任务当前没有可取消的运行实例。" });
        }
        return true;
      }
      task.cancel_requested = true;
      task.cancel_requested_at = new Date().toISOString();
      await writeTask(task);
      controller.abort();
      sendJson(response, 202, { task });
      return true;
    }
    return false;
  } catch (error) {
    sendJson(response, error?.status === 404 ? 404 : error?.status === 409 ? 409 : 400, { error: error.message });
    return true;
  }
}

const batchStates = new Set([
  "queued",
  "running",
  "paused",
  "watching",
  "completed",
  "failed",
  "cancelled",
]);
const batchItemStates = new Set([
  "queued",
  "fetching",
  "auditing",
  "fixing",
  "verifying",
  "verified_pending_publish",
  "publishing",
  "created",
  "no_changes",
  "skipped",
  "failed",
  "cancelled",
]);
const terminalBatchStates = new Set(["completed", "failed", "cancelled"]);

function batchItemKey(event) {
  if (!event || typeof event !== "object") return "";
  const item = event.item && typeof event.item === "object" ? event.item : null;
  const value = event.item_id ?? event.item_key ?? item?.id ?? item?.key ?? item?.repository;
  return typeof value === "string" && value.length <= 300 && !/[\0\r\n]/.test(value) ? value : "";
}

function findBatchItem(batch, key) {
  return batch.items.find((item) => (
    item.id === key || item.key === key || item.repository === key
  ));
}

function ensureBatchItem(batch, event) {
  const key = batchItemKey(event);
  if (!key) return null;
  let item = findBatchItem(batch, key);
  if (!item) {
    const source = event.item && typeof event.item === "object" ? event.item : event;
    item = {
      key: String(source.key || source.id || key),
      id: String(source.id || source.key || key),
      owner: typeof source.owner === "string" ? source.owner : "",
      repo: typeof source.repo === "string" ? source.repo : "",
      repository: typeof source.repository === "string" ? source.repository : "",
      module_names: Array.isArray(source.module_names)
        ? source.module_names.filter((entry) => typeof entry === "string").slice(0, 1000)
        : Array.isArray(source.modules)
          ? source.modules.filter((entry) => typeof entry === "string").slice(0, 1000)
          : typeof source.module === "string" ? [source.module] : [],
      module_version: typeof source.module_version === "string" ? source.module_version : "",
      source_revision: typeof source.source_revision === "string" ? source.source_revision : "",
      fingerprint: typeof source.fingerprint === "string" ? source.fingerprint : "",
      status: batchItemStates.has(source.status) ? source.status : "queued",
      attempts: Number.isInteger(source.attempts) && source.attempts >= 0 ? source.attempts : 0,
      cycle: Number.isInteger(source.cycle) && source.cycle >= 0 ? source.cycle : batch.cycle || 1,
      validation: source.validation && typeof source.validation === "object"
        ? source.validation
        : {
            check_passed: false,
            build_passed: false,
            test_passed: false,
            check_output: "",
            build_output: "",
            test_output: "",
          },
      report: typeof source.report === "string" ? source.report : "",
      report_path: typeof source.report_path === "string" ? source.report_path : "",
      diff_summary: typeof source.diff_summary === "string" ? source.diff_summary : "",
      changed_files: Array.isArray(source.changed_files) ? source.changed_files.slice(0, 5000) : [],
      additions: Number.isInteger(source.additions) ? source.additions : 0,
      deletions: Number.isInteger(source.deletions) ? source.deletions : 0,
      sensitive_changes: source.sensitive_changes === true,
      retryable: source.retryable === true,
      pr_url: typeof source.pr_url === "string" ? source.pr_url : "",
      error: typeof source.error === "string" ? source.error : "",
      created_at_ms: Number.isSafeInteger(source.created_at_ms) ? source.created_at_ms : Date.now(),
      updated_at_ms: Number.isSafeInteger(source.updated_at_ms) ? source.updated_at_ms : Date.now(),
    };
    batch.items.push(item);
  }
  return item;
}

/** Apply a canonical worker event to the persisted batch summary. */
export function applyBatchEvent(batch, rawEvent) {
  const sourceEvent = redactBatchValue(rawEvent);
  const event = sourceEvent.kind
    ? {
        ...(sourceEvent.data && typeof sourceEvent.data === "object" ? sourceEvent.data : {}),
        type: sourceEvent.kind,
        item_id: sourceEvent.item_key,
        cycle: sourceEvent.cycle,
        message: sourceEvent.message,
        timestamp_ms: sourceEvent.timestamp_ms,
      }
    : sourceEvent;
  if (event.type === "snapshot_fetched" && Array.isArray(event.items)) {
    for (const source of event.items) {
      if (!source || typeof source !== "object") continue;
      ensureBatchItem(batch, { type: "item_enqueued", item: source });
    }
    if (Number.isInteger(event.cycle) && event.cycle >= 0) batch.cycle = event.cycle;
  }
  if (event.type === "item_enqueued") ensureBatchItem(batch, event);
  const item = ensureBatchItem(batch, event);
  if (item) {
    if (event.item && typeof event.item === "object") {
      const source = event.item;
      if (typeof source.repository === "string") item.repository = source.repository;
      if (Array.isArray(source.module_names) || Array.isArray(source.modules)) {
        item.module_names = (source.module_names || source.modules)
          .filter((entry) => typeof entry === "string")
          .slice(0, 1000);
      }
      if (typeof source.source_revision === "string") item.source_revision = source.source_revision;
      if (typeof source.fingerprint === "string") item.fingerprint = source.fingerprint;
    }
    const nextStatus = event.status ?? event.state ?? event.item?.status;
    if ((event.type === "item_state" || event.type === "item_enqueued") && batchItemStates.has(nextStatus)) {
      item.status = nextStatus;
    }
    if (event.type === "validation") item.validation = event.validation ?? event.result ?? event;
    if (event.type === "publish") {
      const url = event.pr_url ?? event.url;
      if (typeof url === "string") item.pr_url = url;
      if (event.status === "created" || event.created === true || item.pr_url) item.status = "created";
    }
    if (typeof event.error === "string") item.error = event.error;
    if (typeof event.message === "string" && event.type === "item_state" && item.status === "failed") {
      item.error = event.message;
    }
    if (Number.isInteger(event.attempts) && event.attempts >= 0) item.attempts = event.attempts;
    item.updated_at_ms = Number.isSafeInteger(event.timestamp_ms) ? event.timestamp_ms : Date.now();
  }
  if (event.type === "cycle" && Number.isInteger(event.cycle) && event.cycle >= 0) {
    batch.cycle = event.cycle;
  }
  if (event.type === "batch_state") {
    const state = event.status ?? event.state;
    if (batchStates.has(state)) batch.status = state;
  }
  if (event.type === "worker_started") batch.status = batch.config?.watch ? "watching" : "running";
  if (event.type === "batch_completed") batch.status = batch.config?.watch ? "watching" : "completed";
  if (event.type === "batch_failed") {
    batch.status = "failed";
    if (typeof event.message === "string") batch.error = event.message;
  }
  batch.counts = batchCounters(batch.items);
  batch.updated_at_ms = Number.isSafeInteger(event.timestamp_ms) ? event.timestamp_ms : Date.now();
  return batch;
}

export function eventForBatchOutput(line) {
  let event;
  try { event = typeof line === "string" ? JSON.parse(line) : line; } catch { return null; }
  if (!event || typeof event !== "object" || Array.isArray(event)) return null;
  const kind = typeof event.kind === "string" ? event.kind : event.type;
  if (typeof kind !== "string") return null;
  const accepted = new Set([
    "batch_created",
    "snapshot_fetched",
    "item_enqueued",
    "item_state",
    "validation",
    "publish",
    "batch_state",
    "cycle",
    "warning",
    "error",
    "log",
    "batch_completed",
    "batch_failed",
    "worker_started",
  ]);
  return accepted.has(kind) ? redactBatchValue(event) : null;
}

function canonicalBatchEvent(id, rawEvent) {
  const event = redactBatchValue(rawEvent);
  if (typeof event.kind === "string") {
    return {
      kind: event.kind,
      batch_id: id,
      item_key: typeof event.item_key === "string" ? event.item_key : "",
      cycle: Number.isInteger(event.cycle) ? event.cycle : 0,
      timestamp_ms: Number.isSafeInteger(event.timestamp_ms) ? event.timestamp_ms : Date.now(),
      message: typeof event.message === "string" ? event.message : "",
      data: event.data && typeof event.data === "object" ? event.data : {},
    };
  }
  const kind = typeof event.type === "string" ? event.type : "log";
  const ignored = new Set(["type", "batch_id", "item_id", "item_key", "cycle", "timestamp", "timestamp_ms", "message"]);
  const data = {};
  for (const [key, value] of Object.entries(event)) if (!ignored.has(key)) data[key] = value;
  return {
    kind,
    batch_id: id,
    item_key: batchItemKey(event),
    cycle: Number.isInteger(event.cycle) ? event.cycle : 0,
    timestamp_ms: Number.isSafeInteger(event.timestamp_ms) ? event.timestamp_ms : Date.now(),
    message: typeof event.message === "string" ? event.message : "",
    data,
  };
}

// The batch worker orchestrates untrusted repository clones, so it receives a
// small explicit environment instead of the entire server process. GitHub
// credentials are deliberately omitted: publishing relies on the local `gh`
// CLI configuration, and repository subprocesses never inherit this block.
function workerEnvironment(dataDirectory) {
  const names = [
    "PATH",
    "HOME",
    "USERPROFILE",
    "LOCALAPPDATA",
    "APPDATA",
    "XDG_CONFIG_HOME",
    "GH_CONFIG_DIR",
    "SystemRoot",
    "ComSpec",
    "PATHEXT",
    "TEMP",
    "TMP",
    "TMPDIR",
    "MOON_HOME",
    "MOONBIT_HOME",
    "MOONSAGE_API_KEY",
    "MOONSAGE_BASE_URL",
    "MOONSAGE_MODEL",
    "MOONSAGE_PROVIDER",
    "MOONSAGE_AGENT_BIN",
    "MOONSAGE_AGENT_TIMEOUT_MS",
  ];
  const env = {};
  for (const name of names) {
    if (process.env[name] !== undefined) env[name] = process.env[name];
  }
  env.MOONSAGE_DATA_DIR = dataDirectory;
  return env;
}

function defaultBatchWorkerCommand(batch, dataDirectory) {
  const configuredBin = process.env.MOONSAGE_AGENT_BIN;
  const builtBin = !configuredBin && existsSync(releaseAgentBin) ? releaseAgentBin : null;
  const executable = configuredBin || builtBin || "moon";
  const workerArgs = ["batch-audit", "--worker", "--batch-id", batch.id, "--stream-json"];
  const args = configuredBin || builtBin
    ? workerArgs
    : ["run", "cmd/main", "--", ...workerArgs];
  return {
    executable,
    args,
    options: {
      cwd: root,
      windowsHide: true,
      detached: process.platform !== "win32",
      stdio: ["ignore", "pipe", "pipe"],
      env: workerEnvironment(dataDirectory),
    },
  };
}

/** Run the MoonBit batch worker and translate its JSONL stdout into events. */
export async function runBatchWorker(batch, emit, signal, context = {}) {
  const command = defaultBatchWorkerCommand(batch, context.dataDirectory || activeDataRoot);
  const spawnWorker = context.workerSpawner || spawn;
  return new Promise((resolveWorker) => {
    let child;
    try {
      child = spawnWorker(command.executable, command.args, command.options);
    } catch (error) {
      resolveWorker({ code: 1, error: error.message });
      return;
    }
    context.onChild?.(child);
    let pending = "";
    let stderr = "";
    let outputBytes = 0;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", abort);
      resolveWorker(result);
    };
    const acceptLine = (line) => {
      if (!line.trim()) return;
      const event = eventForBatchOutput(line);
      if (event) emit(event);
    };
    const abort = () => {
      killProcessTree(child);
      finish({ code: null, aborted: true });
    };
    signal?.addEventListener("abort", abort, { once: true });
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      outputBytes += Buffer.byteLength(chunk);
      if (outputBytes > 16 * 1024 * 1024) {
        killProcessTree(child);
        finish({ code: 1, error: "Batch worker output exceeded 16 MB." });
        return;
      }
      pending += chunk;
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";
      for (const line of lines) acceptLine(line);
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk) => { stderr = (stderr + chunk).slice(-65_536); });
    child.once?.("error", (error) => finish({ code: 1, error: error.message }));
    child.once?.("close", (code, childSignal) => {
      if (pending.trim()) acceptLine(pending);
      finish({
        code,
        signal: childSignal,
        error: code === 0 ? "" : stderr.trim() || `Batch worker exited with code ${code}.`,
      });
    });
  });
}

function createBatchController({ dataDirectory, workerRunner, workerSpawner } = {}) {
  const storeRoot = dataDirectory || activeDataRoot;
  const running = new Map();
  const subscribers = new Map();
  const controlWrites = new Map();
  let stopping = false;

  const broadcast = (id, event) => {
    for (const listener of subscribers.get(id) || []) {
      try { listener(event); } catch { /* disconnected subscriber */ }
    }
  };

  const writeControl = (id, action, itemId = "") => {
    const previous = controlWrites.get(id) || Promise.resolve();
    const next = previous.catch(() => {}).then(async () => {
      const paths = batchPaths(requireBatchId(id), storeRoot);
      await mkdir(paths.directory, { recursive: true });
      let existing = { pause: false, cancel: false, approved_items: [], retry_items: [], updated_at_ms: 0 };
      try {
        const document = JSON.parse(await readFile(paths.control, "utf8"));
        if (document && typeof document === "object") {
          existing = {
            pause: document.pause === true,
            cancel: document.cancel === true,
            approved_items: Array.isArray(document.approved_items)
              ? document.approved_items.filter((entry) => typeof entry === "string")
              : [],
            retry_items: Array.isArray(document.retry_items)
              ? document.retry_items.filter((entry) => typeof entry === "string")
              : [],
            updated_at_ms: Number.isSafeInteger(document.updated_at_ms) ? document.updated_at_ms : 0,
          };
        }
      } catch (error) {
        if (error.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
      }
      const clearsPause = ["run", "resume", "retry", "approve"].includes(action);
      const clearsCancel = ["run", "resume", "retry", "approve"].includes(action);
      const control = {
        pause: action === "pause" ? true : clearsPause ? false : existing.pause,
        cancel: action === "cancel" ? true : clearsCancel ? false : existing.cancel,
        approved_items: action === "approve" && itemId
          ? [...new Set([...existing.approved_items, itemId])]
          : existing.approved_items,
        retry_items: action === "retry" && itemId
          ? [...new Set([...existing.retry_items, itemId])]
          : existing.retry_items,
        updated_at_ms: Date.now(),
      };
      await writeFile(paths.control, JSON.stringify(control, null, 2) + "\n", "utf8");
      return control;
    });
    const tracked = next.catch(() => {});
    controlWrites.set(id, tracked);
    return next.finally(() => {
      if (controlWrites.get(id) === tracked) controlWrites.delete(id);
    });
  };

  const runInjected = async (batch, emit, signal, onChild) => {
    const runner = workerRunner || runBatchWorker;
    const result = await runner(batch, emit, signal, {
      dataDirectory: storeRoot,
      workerSpawner,
      onChild,
      paths: batchPaths(batch.id, storeRoot),
    });
    if (result && typeof result[Symbol.asyncIterator] === "function") {
      for await (const event of result) emit(event);
      return {};
    }
    if (Array.isArray(result?.events)) for (const event of result.events) emit(event);
    return result || {};
  };

  async function start(id, { recovery = false, allowTerminal = false } = {}) {
    requireBatchId(id);
    if (running.has(id)) throw batchError("Batch worker is already running.", 409);
    const batch = await readBatch(id, storeRoot);
    if (terminalBatchStates.has(batch.status) && !recovery && !allowTerminal) {
      throw batchError("Completed, failed, or cancelled batches must be retried explicitly.", 409);
    }
    const controller = new AbortController();
    const state = { controller, child: null, promise: null };
    running.set(id, state);
    try {
      await writeControl(id, "run");
    } catch (error) {
      running.delete(id);
      throw error;
    }
    const emit = (event) => {
      const accepted = eventForBatchOutput(event);
      if (!accepted) return;
      // The MoonBit worker persists the record and JSONL before emitting to
      // stdout. The server only fans the event out to live SSE clients.
      broadcast(id, canonicalBatchEvent(id, accepted));
    };
    state.promise = (async () => {
      let result;
      try {
        result = await runInjected(batch, emit, controller.signal, (child) => { state.child = child; });
        const latest = await readBatch(id, storeRoot);
        if (stopping || result?.aborted || ["paused", "cancelled"].includes(latest.status)) return;
        if (result?.error || (result?.code !== undefined && result.code !== 0)) {
          console.error(`MoonSage batch worker ${id} failed; inspect the persisted batch report.`);
        }
      } catch {
        if (!stopping) console.error(`MoonSage batch worker ${id} failed; inspect the persisted batch report.`);
      } finally {
        running.delete(id);
      }
    })();
    return { ...batch, status: batch.config?.watch ? "watching" : "running" };
  }

  const pause = async (id) => {
    const batch = await readBatch(id, storeRoot);
    if (!["running", "watching"].includes(batch.status)) throw batchError("Only running batches can be paused.", 409);
    await writeControl(id, "pause");
    return batch;
  };

  const resume = async (id) => {
    const batch = await readBatch(id, storeRoot);
    let pauseRequested = false;
    try {
      pauseRequested = JSON.parse(await readFile(batchPaths(id, storeRoot).control, "utf8"))?.pause === true;
    } catch { /* a missing control file means no pending pause */ }
    if (batch.status !== "paused" && !pauseRequested) {
      throw batchError("Only paused batches can be resumed.", 409);
    }
    if (running.has(id)) {
      await writeControl(id, "resume");
      return batch;
    }
    await start(id);
    return batch;
  };

  const cancel = async (id) => {
    const batch = await readBatch(id, storeRoot);
    if (batch.status === "cancelled") return batch;
    if (batch.status === "completed") throw batchError("Completed batches cannot be cancelled.", 409);
    await writeControl(id, "cancel");
    // The control file is the durable source of truth, while the in-memory
    // controller must also stop the active child promptly. Without aborting
    // here a package could continue spending its full 20-minute budget before
    // the worker observes the request at its next queue boundary.
    const state = running.get(id);
    if (state) {
      state.controller.abort();
      if (state.child) killProcessTree(state.child);
    }
    return batch;
  };

  const retry = async (id, itemId) => {
    const batch = await readBatch(id, storeRoot);
    const item = findBatchItem(batch, itemId);
    if (!item) throw batchError("Batch item is not found.", 404);
    if (!["failed", "cancelled", "skipped", "no_changes"].includes(item.status)) {
      throw batchError("Only terminal non-PR items can be retried.", 409);
    }
    await writeControl(id, "retry", item.id || itemId);
    if (!running.has(id)) await start(id, { allowTerminal: true });
    return batch;
  };

  const approve = async (id, itemId) => {
    const batch = await readBatch(id, storeRoot);
    const item = findBatchItem(batch, itemId);
    if (!item) throw batchError("Batch item is not found.", 404);
    if (item.status !== "verified_pending_publish") {
      throw batchError("Only verified pending items can be approved.", 409);
    }
    await writeControl(id, "approve", item.id || itemId);
    if (!running.has(id)) await start(id, { allowTerminal: true });
    return batch;
  };

  const recover = async () => {
    let entries;
    try { entries = await readdir(batchStorePath(storeRoot), { withFileTypes: true }); }
    catch (error) { if (error.code === "ENOENT") return; throw error; }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json") || entry.name.endsWith(".control.json")) continue;
      const id = entry.name.slice(0, -5);
      if (!batchIdPattern.test(id)) continue;
      let batch;
      try { batch = await readBatch(id, storeRoot); } catch { continue; }
      if (!["running", "watching"].includes(batch.status)) continue;
      // A server restart terminates its worker process, so any remaining lock
      // for a persisted running batch belongs to that interrupted worker.
      await rm(batchPaths(id, storeRoot).lock, { force: true }).catch(() => {});
      await start(id, { recovery: true }).catch(async () => {
        console.error(`MoonSage batch recovery failed for ${id}.`);
      });
    }
  };

  const subscribe = (id, listener) => {
    let listeners = subscribers.get(id);
    if (!listeners) {
      listeners = new Set();
      subscribers.set(id, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) subscribers.delete(id);
    };
  };

  const stopAll = () => {
    stopping = true;
    for (const state of running.values()) {
      state.controller.abort();
      if (state.child) killProcessTree(state.child);
    }
  };

  return { approve, cancel, pause, recover, resume, retry, start, stopAll, subscribe, storeRoot };
}

function beginSse(response) {
  response.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    ...secureHeaders,
  });
  response.flushHeaders();
}

function sendSse(response, event, index = "") {
  if (response.writableEnded || response.destroyed) return;
  if (index !== "") response.write(`id: ${index}\n`);
  const kind = typeof event?.kind === "string" ? event.kind : event?.type;
  if (typeof kind === "string" && /^[a-z0-9_-]{1,64}$/i.test(kind)) response.write(`event: ${kind}\n`);
  response.write(`data: ${JSON.stringify(event)}\n\n`);
}

async function listBatches(dataDirectory) {
  const batches = [];
  try {
    const entries = await readdir(batchStorePath(dataDirectory), { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json") || entry.name.endsWith(".control.json")) continue;
      const id = entry.name.slice(0, -5);
      if (!batchIdPattern.test(id)) continue;
      try { batches.push(await readBatch(id, dataDirectory)); } catch { /* ignore partial metadata */ }
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  batches.sort((a, b) => Number(b.updated_at_ms || 0) - Number(a.updated_at_ms || 0));
  return batches;
}

async function createBatch(document, controller) {
  const config = normalizeBatchConfig(document);
  const now = Date.now();
  const batch = {
    schema_version: 1,
    id: randomUUID(),
    status: "queued",
    config,
    cycle: 1,
    items: [],
    pr_count: 0,
    created_at_ms: now,
    updated_at_ms: now,
    last_snapshot_at_ms: now,
    last_error: "",
  };
  await writeBatch(batch, controller.storeRoot);
  return readBatch(batch.id, controller.storeRoot);
}

async function serveBatchEvents(request, response, id, controller) {
  if (request.method !== "GET") {
    sendJson(response, 405, { error: "Only GET is supported." });
    return;
  }
  await readBatch(id, controller.storeRoot);
  beginSse(response);
  const events = await readBatchEvents(id, controller.storeRoot);
  const requestedEventId = Number(request.headers["last-event-id"] || queryPath(request.url, "after") || -1);
  const lastEventId = Number.isInteger(requestedEventId) && requestedEventId >= -1 ? requestedEventId : -1;
  for (let index = 0; index < events.length; index += 1) {
    if (index > lastEventId) sendSse(response, events[index], index);
  }
  const unsubscribe = controller.subscribe(id, (event) => sendSse(response, event));
  const keepalive = setInterval(() => {
    if (!response.writableEnded && !response.destroyed) response.write(": keep-alive\n\n");
  }, 15_000);
  keepalive.unref?.();
  request.on("close", () => {
    clearInterval(keepalive);
    unsubscribe();
  });
}

async function serveBatches(request, response, pathname, controller) {
  try {
    if (pathname === "/api/batches" && request.method === "GET") {
      sendJson(response, 200, { batches: (await listBatches(controller.storeRoot)).map(publicBatch) });
      return true;
    }
    if (pathname === "/api/batches" && request.method === "POST") {
      if (!requireJsonContentType(request)) {
        sendJson(response, 415, { error: "Writes require application/json." });
        return true;
      }
      const batch = await createBatch(await readJsonBody(request), controller);
      sendJson(response, 201, { batch: publicBatch(batch) });
      return true;
    }
    const events = pathname.match(/^\/api\/batches\/([^/]+)\/events$/);
    if (events) {
      await serveBatchEvents(request, response, decodeURIComponent(events[1]), controller);
      return true;
    }
    const action = pathname.match(/^\/api\/batches\/([^/]+)\/(run|pause|resume|cancel)$/);
    if (action) {
      if (request.method !== "POST") {
        sendJson(response, 405, { error: "Only POST is supported." });
        return true;
      }
      const id = decodeURIComponent(action[1]);
      let batch;
      if (action[2] === "run") batch = await controller.start(id);
      else if (action[2] === "pause") batch = await controller.pause(id);
      else if (action[2] === "resume") batch = await controller.resume(id);
      else batch = await controller.cancel(id);
      sendJson(response, action[2] === "run" ? 202 : 200, { batch: publicBatch(batch) });
      return true;
    }
    const itemAction = pathname.match(/^\/api\/batches\/([^/]+)\/items\/([^/]+)\/(retry|approve)$/);
    if (itemAction) {
      if (request.method !== "POST") {
        sendJson(response, 405, { error: "Only POST is supported." });
        return true;
      }
      const id = decodeURIComponent(itemAction[1]);
      const itemId = decodeURIComponent(itemAction[2]);
      const batch = itemAction[3] === "retry"
        ? await controller.retry(id, itemId)
        : await controller.approve(id, itemId);
      sendJson(response, 202, { batch: publicBatch(batch) });
      return true;
    }
    const detail = pathname.match(/^\/api\/batches\/([^/]+)$/);
    if (detail && request.method === "GET") {
      const batch = await readBatch(decodeURIComponent(detail[1]), controller.storeRoot);
      sendJson(response, 200, { batch: publicBatch(batch) });
      return true;
    }
    sendJson(response, 405, { error: "Unsupported batch operation." });
    return true;
  } catch (error) {
    const status = [404, 409, 413].includes(error?.status) ? error.status : 400;
    if (response.headersSent) {
      sendSse(response, { type: "error", message: error.message });
      try { response.end(); } catch { /* client disconnected */ }
    } else {
      sendJson(response, status, { error: error.message });
    }
    return true;
  }
}

export function serve({
  listenPort = port,
  agentRunner = runAgent,
  batchWorker,
  batchRunner,
  workerRunner,
  workerSpawner,
  workspaceRoot = root,
  workspaceDataDirectory,
} = {}) {
  if (workspaceDataDirectory) activeDataRoot = normalize(resolve(workspaceDataDirectory));
  activeWorktreeManager = new WorktreeManager({ dataDirectory: activeDataRoot });
  const batchController = createBatchController({
    dataDirectory: activeDataRoot,
    workerRunner: batchWorker || batchRunner || workerRunner,
    workerSpawner,
  });
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
    if (pathname === "/api/batches" || pathname.startsWith("/api/batches/")) {
      void serveBatches(request, response, pathname, batchController);
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
    void activeWorktreeManager.recover().catch((error) => {
      console.error(`MoonSage worktree recovery failed: ${error.message}`);
    });
    void batchController.recover().catch((error) => {
      console.error(`MoonSage batch recovery failed: ${error.message}`);
    });
    console.log(`MoonSage frontend: http://127.0.0.1:${activePort}/frontend/`);
  });
  server.on("close", () => batchController.stopAll());
  server.batchController = batchController;
  return server;
}

const entry = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (entry === import.meta.url) serve();
