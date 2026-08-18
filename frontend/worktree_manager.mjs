import { execFile } from "node:child_process";
import { copyFile, mkdir, open, readdir, lstat, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const WORKTREE_REGISTRY_VERSION = 2;
export const DEFAULT_LEASE_MS = 15 * 60 * 1000;
export const DEFAULT_INCLUDE_BYTES = 64 * 1024;
export const DEFAULT_WORKTREE_FILES = 20_000;
export const DEFAULT_INCLUDE_TOTAL_BYTES = 8 * 1024 * 1024;
export const DEFAULT_WORKTREE_LIMIT = 15;
const LEASE_LOCK_STALE_MS = 30_000;

const idPattern = /^[a-z0-9][a-z0-9-]{7,79}$/;
const branchPattern = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,179}$/;
const refPattern = /^[A-Za-z0-9][A-Za-z0-9._/@-]{0,255}$/;
const ignoredNames = new Set([
  ".git",
  ".mooncakes",
  ".moonsage",
  ".cache",
  "_build",
  "_build.bak",
  "node_modules",
  "target",
]);

/** Errors carry a stable code so HTTP/CLI adapters can map them later. */
export class WorktreeError extends Error {
  constructor(message, code = "WORKTREE_ERROR", details = undefined) {
    super(message);
    this.name = "WorktreeError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function fail(message, code = "WORKTREE_ERROR", details = undefined) {
  throw new WorktreeError(message, code, details);
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function nowIso(clock) {
  const value = clock ? clock() : new Date();
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? new Date().toISOString() : date.toISOString();
}

function timestamp(value, fallback) {
  if (typeof value !== "string" || !value.trim()) return fallback;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? fallback : date.toISOString();
}

function string(value, fallback = "") {
  return typeof value === "string" ? value : fallback;
}

function boolean(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function id(value, makeId = randomUUID) {
  return typeof value === "string" && idPattern.test(value) ? value : makeId();
}

function slash(value) {
  return value.replaceAll("\\", "/");
}

function lexicalAbsolute(value) {
  if (typeof value !== "string" || !value.trim() || value.includes("\0")) {
    fail("A workspace path is required.", "INVALID_PATH");
  }
  return normalize(resolve(value));
}

function pathWithin(root, target) {
  const rel = relative(resolve(root), resolve(target));
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function samePath(left, right) {
  const leftPath = normalize(resolve(left));
  const rightPath = normalize(resolve(right));
  return process.platform === "win32"
    ? leftPath.toLowerCase() === rightPath.toLowerCase()
    : leftPath === rightPath;
}

function assertPathWithin(root, target, code = "INVALID_PATH") {
  if (!pathWithin(root, target)) fail("Path escapes its workspace root.", code);
  return target;
}

function safeName(value, fallback = "worktree") {
  const candidate = string(value, fallback).trim();
  if (!candidate || candidate === "." || candidate === ".." || /[\\/\0\r\n]/.test(candidate)) {
    fail("Invalid worktree name.", "INVALID_NAME");
  }
  return candidate.slice(0, 120);
}

/**
 * Validate a path supplied by a user or by .worktreeinclude. The returned
 * value always uses slash separators and never contains a parent component.
 * Globs are accepted only for include entries, never for filesystem writes.
 */
export function validateRelativePath(value, { allowGlob = false } = {}) {
  if (typeof value !== "string" || !value.trim() || value.includes("\0")) {
    fail("Relative path is required.", "INVALID_PATH");
  }
  const normalized = slash(value.trim());
  if (
    normalized.startsWith("/") ||
    /^[A-Za-z]:($|\/)/.test(normalized) ||
    normalized.startsWith("~//") ||
    normalized.startsWith("~/")
  ) {
    fail("Absolute paths are not allowed.", "INVALID_PATH");
  }
  const parts = normalized.split("/");
  const output = [];
  for (const part of parts) {
    if (!part || part === ".") continue;
    if (part === "..") fail("Parent paths are not allowed.", "INVALID_PATH");
    if (!allowGlob && /[*?\[\]{}]/.test(part)) {
      fail("Glob patterns are not allowed here.", "INVALID_PATH");
    }
    if (/[\r\n]/.test(part)) fail("Control characters are not allowed in paths.", "INVALID_PATH");
    output.push(part);
  }
  if (!output.length) fail("Relative path is empty.", "INVALID_PATH");
  return output.join("/");
}

function includeEntry(value) {
  const normalized = validateRelativePath(value, { allowGlob: true });
  const parts = normalized.split("/");
  for (const part of parts) {
    const plain = part.replace(/[\\*?\[\]{}]/g, "").toLowerCase();
    if (ignoredNames.has(plain) || plain === ".worktreeinclude" && parts.length > 1) {
      // A caller may explicitly include a root .worktreeinclude file, but
      // metadata directories must never be copied through a pattern.
      if (plain !== ".worktreeinclude") fail(".worktreeinclude may not copy protected directories.", "UNSAFE_INCLUDE");
    }
  }
  return normalized;
}

/** Parse the optional ignored-file copy manifest with strict path checks. */
export function parseWorktreeInclude(source) {
  if (source === undefined || source === null || source === "") return [];
  if (typeof source !== "string") fail(".worktreeinclude must be UTF-8 text.", "UNSAFE_INCLUDE");
  const entries = [];
  for (const raw of source.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const entry = includeEntry(line);
    if (!entries.includes(entry)) entries.push(entry);
  }
  return entries;
}

function globRegex(pattern) {
  let output = "^";
  for (let index = 0; index < pattern.length; index += 1) {
    const char = pattern[index];
    if (char === "*") {
      if (pattern[index + 1] === "*") {
        index += 1;
        output += ".*";
      } else {
        output += "[^/]*";
      }
    } else if (char === "?") {
      output += "[^/]";
    } else if (char === "[") {
      const end = pattern.indexOf("]", index + 1);
      if (end > index + 1) {
        output += pattern.slice(index, end + 1);
        index = end;
      } else {
        output += "\\[";
      }
    } else {
      output += char.replace(/[\\^$+?.()|{}]/g, "\\$&");
    }
  }
  return new RegExp(`${output}$`);
}

async function canonicalDirectory(path) {
  const candidate = lexicalAbsolute(path);
  const components = slash(candidate).split("/").filter(Boolean).map((part) => part.toLowerCase());
  if (components.some((part) => ignoredNames.has(part) || part.startsWith("_audit_ws_"))) {
    fail("Generated and hidden directories cannot be workspaces.", "INVALID_PATH");
  }
  const entry = await lstat(candidate).catch((error) => {
    if (error.code === "ENOENT") fail("Workspace directory does not exist.", "NOT_FOUND");
    throw error;
  });
  if (!entry.isDirectory() || entry.isSymbolicLink()) fail("Workspace path must be a real directory.", "INVALID_PATH");
  return realpath(candidate);
}

async function canonicalFile(root, relativePath, { maxBytes = DEFAULT_INCLUDE_BYTES } = {}) {
  const rel = validateRelativePath(relativePath);
  const path = resolve(root, rel);
  assertPathWithin(root, path);
  const entry = await lstat(path).catch((error) => {
    if (error.code === "ENOENT") fail(`Included path does not exist: ${rel}`, "UNSAFE_INCLUDE");
    throw error;
  });
  if (entry.isSymbolicLink()) fail(`Symbolic links are not allowed: ${rel}`, "UNSAFE_INCLUDE");
  const canonicalRoot = await realpath(root);
  const canonicalPath = await realpath(path);
  assertPathWithin(canonicalRoot, canonicalPath, "UNSAFE_INCLUDE");
  if (entry.isFile() && entry.size > maxBytes) fail(`Included file is too large: ${rel}`, "UNSAFE_INCLUDE");
  return { path, relativePath: rel, entry };
}

async function verifyDirectoryParents(root, relativePath) {
  const rel = validateRelativePath(relativePath);
  let current = root;
  for (const segment of rel.split("/").slice(0, -1)) {
    current = join(current, segment);
    const entry = await lstat(current).catch((error) => {
      if (error.code === "ENOENT") return null;
      throw error;
    });
    if (entry?.isSymbolicLink()) fail(`Symbolic link in target path: ${rel}`, "SNAPSHOT_UNSAFE");
    if (entry && !entry.isDirectory()) fail(`Target path parent is not a directory: ${rel}`, "SNAPSHOT_UNSAFE");
  }
}

async function collectIncludeMatches(root, pattern, maxFiles = DEFAULT_WORKTREE_FILES) {
  const matcher = globRegex(pattern);
  const matches = [];
  async function visit(directory, prefix) {
    if (matches.length >= maxFiles) return;
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (matches.length >= maxFiles) return;
      if (entry.name === ".git" || entry.name === ".moonsage" || entry.name === ".mooncakes") continue;
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) fail(`Symbolic links are not allowed: ${rel}`, "UNSAFE_INCLUDE");
      if (matcher.test(rel)) matches.push(rel);
      if (entry.isDirectory()) await visit(path, rel);
    }
  }
  if (!/[?*\[]/.test(pattern)) return [pattern];
  await visit(root, "");
  return matches;
}

async function copyIncludeTree(sourceRoot, targetRoot, relativePath, maxBytes) {
  const source = await canonicalFile(sourceRoot, relativePath, { maxBytes });
  const destination = resolve(targetRoot, source.relativePath);
  assertPathWithin(targetRoot, destination, "UNSAFE_INCLUDE");
  let parent = dirname(destination);
  while (pathWithin(targetRoot, parent) && parent !== resolve(targetRoot)) {
    const existing = await lstat(parent).catch(() => null);
    if (existing?.isSymbolicLink()) fail(`Symbolic link in include destination: ${source.relativePath}`, "UNSAFE_INCLUDE");
    parent = dirname(parent);
  }
  if (source.entry.isDirectory()) {
    await mkdir(destination, { recursive: true });
    const children = await readdir(source.path, { withFileTypes: true });
    for (const child of children) {
      if (child.isSymbolicLink()) fail(`Symbolic links are not allowed: ${source.relativePath}/${child.name}`, "UNSAFE_INCLUDE");
      await copyIncludeTree(sourceRoot, targetRoot, `${source.relativePath}/${child.name}`, maxBytes);
    }
  } else if (source.entry.isFile()) {
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(source.path, destination);
  } else {
    fail(`Included path is not a regular file or directory: ${source.relativePath}`, "UNSAFE_INCLUDE");
  }
  return source.relativePath;
}

/** Copy explicitly listed ignored files into a freshly-created worktree. */
export async function copyWorktreeInclude(sourceRoot, targetRoot, {
  maxBytes = DEFAULT_INCLUDE_BYTES,
  maxFiles = DEFAULT_WORKTREE_FILES,
  maxTotalBytes = DEFAULT_INCLUDE_TOTAL_BYTES,
} = {}) {
  const source = await canonicalDirectory(sourceRoot);
  const target = await canonicalDirectory(targetRoot);
  const manifestPath = join(source, ".worktreeinclude");
  const manifest = await readFile(manifestPath, { encoding: "utf8" }).catch((error) => {
    if (error.code === "ENOENT") return "";
    throw error;
  });
  const entries = parseWorktreeInclude(manifest);
  const copied = [];
  let totalBytes = 0;
  const files = [];
  const fileSet = new Set();
  async function collectTree(relativePath) {
    const sourceEntry = await canonicalFile(source, relativePath, { maxBytes });
    if (sourceEntry.entry.isDirectory()) {
      const children = await readdir(sourceEntry.path, { withFileTypes: true });
      children.sort((a, b) => a.name.localeCompare(b.name));
      for (const child of children) {
        if (child.isSymbolicLink()) fail(`Symbolic links are not allowed: ${relativePath}/${child.name}`, "UNSAFE_INCLUDE");
        await collectTree(`${relativePath}/${child.name}`);
      }
      return;
    }
    if (!sourceEntry.entry.isFile()) fail(`Included path is not a regular file: ${relativePath}`, "UNSAFE_INCLUDE");
    if (fileSet.has(sourceEntry.relativePath)) return;
    if (files.length >= maxFiles) fail(".worktreeinclude contains too many files.", "UNSAFE_INCLUDE");
    totalBytes += sourceEntry.entry.size;
    if (totalBytes > maxTotalBytes) fail(".worktreeinclude exceeds the total size limit.", "UNSAFE_INCLUDE");
    fileSet.add(sourceEntry.relativePath);
    files.push(sourceEntry.relativePath);
  }
  for (const entry of entries) {
    const matches = await collectIncludeMatches(source, entry, maxFiles - copied.length);
    for (const match of matches) await collectTree(match);
  }
  for (const relativePath of files) {
    const sourceEntry = await canonicalFile(source, relativePath, { maxBytes });
    const destination = resolve(target, sourceEntry.relativePath);
    assertPathWithin(target, destination, "UNSAFE_INCLUDE");
    await verifyDirectoryParents(target, sourceEntry.relativePath);
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(sourceEntry.path, destination);
    copied.push(sourceEntry.relativePath);
  }
  return [...new Set(copied)];
}

function normalizeRecord(raw, { now, makeId } = {}) {
  const value = asObject(raw);
  const root = string(value.root, string(value.path));
  if (!root || root.includes("\0")) return null;
  const managed = value.kind === "worktree" || value.managed === true;
  const kind = managed ? "worktree" : "local";
  const created = timestamp(value.created_at, now);
  const lastUsed = timestamp(value.last_used_at, created);
  const cleanup = ["never", "manual", "prune"].includes(value.cleanup)
    ? value.cleanup
    : managed ? "prune" : "never";
  const repositoryRoot = normalize(string(
    value.repo_root,
    string(value.repository_root, string(value.repository, "")),
  ));
  const record = {
    id: id(value.id, makeId),
    name: safeName(value.name, basename(root)),
    root: normalize(root),
    path: normalize(root),
    kind,
    managed,
    created_at: created,
    last_used_at: lastUsed,
    pinned: boolean(value.pinned, !managed),
    cleanup,
    repo_root: repositoryRoot,
    repository_root: repositoryRoot,
    common_dir: normalize(string(value.common_dir, "")),
    source_id: string(value.source_id, ""),
    base_ref: string(value.base_ref, "HEAD"),
    head: string(value.head, ""),
    branch: string(value.branch, ""),
    detached: boolean(value.detached, managed),
    lifecycle: string(
      value.lifecycle,
      managed ? (value.cleanup === "never" ? "permanent" : "temporary") : "local",
    ),
    status: string(value.status, "ready"),
    owner_task_id: string(value.owner_task_id, ""),
    owner_session_id: string(value.owner_session_id, ""),
    eligible_for_cleanup: boolean(value.eligible_for_cleanup, false),
    last_error: string(value.last_error, ""),
    last_snapshot_id: string(value.last_snapshot_id, ""),
  };
  if (!managed) {
    record.repo_root = "";
    record.repository_root = "";
    record.common_dir = "";
    record.source_id = "";
    record.base_ref = "";
    record.head = "";
    record.branch = "";
    record.detached = false;
    record.lifecycle = "local";
    record.status = "ready";
    record.owner_task_id = "";
    record.owner_session_id = "";
    record.eligible_for_cleanup = false;
    record.last_snapshot_id = "";
  }
  return record;
}

/** Normalize v1/v2 registry documents without touching the filesystem. */
export function normalizeRegistry(document, { now = new Date().toISOString(), makeId = randomUUID } = {}) {
  const source = asObject(document);
  const records = [];
  const byId = new Map();
  const byRoot = new Map();
  for (const raw of Array.isArray(source.workspaces) ? source.workspaces : []) {
    const record = normalizeRecord(raw, { now, makeId });
    if (!record) continue;
    if (byId.has(record.id) || byRoot.has(record.root)) continue;
    byId.set(record.id, record);
    byRoot.set(record.root, record);
    records.push(record);
  }
  records.sort((a, b) => b.last_used_at.localeCompare(a.last_used_at) || a.id.localeCompare(b.id));
  return { version: WORKTREE_REGISTRY_VERSION, workspaces: records };
}

export function migrateRegistry(document, options = {}) {
  const source = asObject(document);
  return {
    registry: normalizeRegistry(source, options),
    migrated: source.version !== WORKTREE_REGISTRY_VERSION,
    from_version: Number.isInteger(source.version) ? source.version : 0,
  };
}

function validBranch(branch) {
  return typeof branch === "string" && branchPattern.test(branch) &&
    !branch.includes("..") && !branch.includes("//") && !branch.endsWith("/") && !branch.endsWith(".lock");
}

function validRef(ref) {
  return typeof ref === "string" && ref.length > 0 && ref.length <= 256 && refPattern.test(ref) &&
    !ref.includes("..") && !ref.includes("//");
}

async function git(cwd, args, { acceptedExitCodes = [], timeout = 30_000 } = {}) {
  try {
    const result = await execFileAsync("git", args, {
      cwd,
      encoding: "utf8",
      timeout,
      maxBuffer: 4 * 1024 * 1024,
      windowsHide: true,
    });
    return { stdout: String(result.stdout || ""), stderr: String(result.stderr || ""), code: 0 };
  } catch (error) {
    const code = Number(error.code);
    if (acceptedExitCodes.includes(code) || acceptedExitCodes.includes(error.code)) {
      return { stdout: String(error.stdout || ""), stderr: String(error.stderr || ""), code };
    }
    throw new WorktreeError(String(error.stderr || error.message || "Git command failed.").trim(), "GIT_ERROR", {
      command: ["git", ...args],
      exitCode: code,
    });
  }
}

async function gitRoot(path) {
  const result = await git(path, ["rev-parse", "--show-toplevel"]);
  return canonicalDirectory(result.stdout.trim());
}

async function gitCommonDir(root) {
  const result = await git(root, ["rev-parse", "--git-common-dir"]);
  const common = result.stdout.trim();
  return realpath(resolve(root, common));
}

async function gitDirty(root) {
  const result = await git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  return result.stdout.length > 0;
}

async function gitRevision(root) {
  const [headResult, statusResult] = await Promise.all([
    git(root, ["rev-parse", "--verify", "HEAD"], { acceptedExitCodes: [128] }),
    git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
  ]);
  const head = headResult.stdout.trim();
  const status = statusResult.stdout;
  return createHash("sha256").update(`${head}\0${status}`).digest("hex");
}

/** Parse `git worktree list --porcelain` into stable records. */
export function parseWorktreeList(output) {
  const result = [];
  let current = null;
  const finish = () => {
    if (current?.path) result.push(current);
    current = null;
  };
  for (const line of String(output || "").split(/\r?\n/)) {
    if (!line) {
      finish();
      continue;
    }
    if (line.startsWith("worktree ")) {
      finish();
      current = { path: line.slice(9), head: "", branch: "", detached: false, locked: false, prunable: false };
    } else if (current && line.startsWith("HEAD ")) current.head = line.slice(5).trim();
    else if (current && line.startsWith("branch ")) {
      const branch = line.slice(7).trim();
      current.branch = branch.startsWith("refs/heads/") ? branch.slice(11) : branch;
    } else if (current && line === "detached") current.detached = true;
    else if (current && line.startsWith("locked")) current.locked = true;
    else if (current && line.startsWith("prunable")) current.prunable = true;
  }
  finish();
  return result;
}

export function parsePorcelainStatus(output) {
  const fields = String(output || "").split("\0");
  const changes = [];
  for (let index = 0; index < fields.length; index += 1) {
    const record = fields[index];
    if (!record || record.length < 4) continue;
    const status = record.slice(0, 2);
    let path = record.slice(3);
    const indexStatus = status[0];
    const worktreeStatus = status[1];
    const rename = indexStatus === "R" || worktreeStatus === "R";
    const copy = indexStatus === "C" || worktreeStatus === "C";
    let oldPath = "";
    // With --porcelain=v1 -z Git emits the new path in this record and the
    // old path as the following NUL-delimited field for renames/copies.
    if (rename || copy) {
      const tab = path.indexOf("\t");
      if (tab >= 0) {
        oldPath = path.slice(0, tab);
        path = path.slice(tab + 1);
      } else if (fields[index + 1]) {
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
      conflicted: indexStatus === "U" || worktreeStatus === "U" || status === "AA" || status === "DD",
      rename,
      copy,
    });
  }
  return changes;
}

function leaseName(id) {
  return `${id}.lease.json`;
}

function leaseLockName(id) {
  return `${id}.lock`;
}

function leaseExpired(lease, nowMs = Date.now()) {
  return !lease || !Number.isFinite(Number(lease.expires_at_ms)) || Number(lease.expires_at_ms) <= nowMs;
}

async function readLease(path) {
  try {
    const value = JSON.parse(await readFile(path, "utf8"));
    return asObject(value);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    return null;
  }
}

export class WorktreeManager {
  constructor({
    dataDirectory = process.env.MOONSAGE_DATA_DIR || join(
      process.platform === "win32" ? (process.env.LOCALAPPDATA || process.env.APPDATA || homedir()) :
        process.platform === "darwin" ? join(homedir(), "Library", "Application Support") :
          process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"),
      "MoonSage",
    ),
    registryPath,
    worktreeDirectory,
    leaseDirectory,
    clock,
    idFactory = randomUUID,
  } = {}) {
    this.dataDirectory = lexicalAbsolute(dataDirectory);
    this.registryPath = lexicalAbsolute(registryPath || join(this.dataDirectory, "workspaces.json"));
    this.worktreeDirectory = lexicalAbsolute(worktreeDirectory || join(this.dataDirectory, "worktrees"));
    this.leaseDirectory = lexicalAbsolute(leaseDirectory || join(this.dataDirectory, "worktree-leases"));
    this.clock = clock || (() => new Date());
    this.idFactory = idFactory;
    this.registryWrite = Promise.resolve();
  }

  now() {
    return nowIso(this.clock);
  }

  async readRegistry() {
    let document;
    try {
      document = JSON.parse(await readFile(this.registryPath, "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") return normalizeRegistry({}, { now: this.now(), makeId: this.idFactory });
      if (error instanceof SyntaxError) fail("Workspace registry is invalid JSON.", "REGISTRY_INVALID");
      throw error;
    }
    const migrated = migrateRegistry(document, { now: this.now(), makeId: this.idFactory });
    // Persist the compatibility upgrade once so a v1 file is not repeatedly
    // interpreted in memory and external readers observe the v2 contract.
    if (migrated.migrated || JSON.stringify(document) !== JSON.stringify(migrated.registry)) {
      await this.writeRegistry(migrated.registry);
    }
    return migrated.registry;
  }

  async writeRegistry(registry) {
    const normalized = normalizeRegistry(registry, { now: this.now(), makeId: this.idFactory });
    const next = this.registryWrite.catch(() => {}).then(async () => {
      await mkdir(dirname(this.registryPath), { recursive: true });
      const temporary = `${this.registryPath}.${process.pid}.${this.idFactory()}.tmp`;
      await writeFile(temporary, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
      try {
        await rename(temporary, this.registryPath);
      } finally {
        await rm(temporary, { force: true }).catch(() => {});
      }
    });
    this.registryWrite = next.catch(() => {});
    await next;
    return normalized;
  }

  async registerWorkspace({ path, root, name, pinned = true } = {}) {
    const canonical = await canonicalDirectory(path || root);
    const registry = await this.readRegistry();
    const existing = registry.workspaces.find((record) => record.kind === "local" && record.root === canonical);
    const now = this.now();
    if (existing) {
      existing.last_used_at = now;
      existing.pinned = pinned === true;
      if (name) existing.name = safeName(name, basename(canonical));
      await this.writeRegistry(registry);
      return existing;
    }
    const record = normalizeRecord({
      id: this.idFactory(),
      name: name || basename(canonical),
      root: canonical,
      kind: "local",
      managed: false,
      pinned,
      created_at: now,
      last_used_at: now,
    }, { now, makeId: this.idFactory });
    registry.workspaces.push(record);
    await this.writeRegistry(registry);
    return record;
  }

  async resolveRecord(idOrRecord) {
    const registry = await this.readRegistry();
    const idValue = typeof idOrRecord === "string" ? idOrRecord : idOrRecord?.id;
    const value = idValue
      ? registry.workspaces.find((record) => record.id === idValue)
      : null;
    if (!value) fail("Workspace record was not found.", "NOT_FOUND");
    return { registry, record: value };
  }

  async createWorktree({
    source,
    sourceRoot,
    workspaceId,
    base = "HEAD",
    baseRef,
    branch = "",
    detached = true,
    name,
    id: requestedId,
    targetPath,
    copyIgnored = true,
    includeMaxBytes = DEFAULT_INCLUDE_BYTES,
    includeMaxTotalBytes = DEFAULT_INCLUDE_TOTAL_BYTES,
    includeMaxFiles = DEFAULT_WORKTREE_FILES,
    lifecycle = "temporary",
    ownerTaskId = "",
    ownerSessionId = "",
  } = {}) {
    let registry = await this.readRegistry();
    let sourceRecord = null;
    if (workspaceId) {
      sourceRecord = registry.workspaces.find((record) => record.id === workspaceId);
      if (!sourceRecord) fail("Source workspace was not found.", "NOT_FOUND");
    }
    const sourcePath = sourceRoot || source || sourceRecord?.root;
    if (!sourcePath) fail("A source workspace is required.", "INVALID_PATH");
    const repositoryRoot = await gitRoot(sourcePath);
    const commonDir = await gitCommonDir(repositoryRoot);
    const ref = baseRef || base;
    if (!validRef(ref)) fail("Invalid base revision.", "INVALID_REF");
    if (branch && !validBranch(branch)) fail("Invalid worktree branch.", "INVALID_BRANCH");
    if (branch && detached) fail("A detached worktree cannot also create a branch.", "INVALID_BRANCH");
    const worktreeId = id(requestedId, this.idFactory);
    if (registry.workspaces.some((record) => record.id === worktreeId)) fail("Worktree id is already registered.", "CONFLICT");
    const target = targetPath
      ? lexicalAbsolute(targetPath)
      : join(this.worktreeDirectory, worktreeId);
    assertPathWithin(this.worktreeDirectory, target, "INVALID_PATH");
    if (target === resolve(this.worktreeDirectory)) fail("Worktree target must be a child directory.", "INVALID_PATH");
    // Validate all record metadata before `git worktree add`, otherwise a bad
    // display name can fail after Git has already registered the checkout.
    const worktreeName = safeName(name || basename(target));
    await verifyDirectoryParents(this.worktreeDirectory, relative(this.worktreeDirectory, target));
    const existingTarget = await lstat(target).catch(() => null);
    if (existingTarget) fail("Worktree target already exists.", "CONFLICT");
    await mkdir(dirname(target), { recursive: true });
    const args = ["worktree", "add"];
    if (detached) args.push("--detach");
    else args.push("-b", branch);
    args.push(target, ref);
    try {
      await git(repositoryRoot, args, { timeout: 120_000 });
    } catch (error) {
      if (branch && /already exists|already checked out|is already used/i.test(error.message)) {
        fail("The branch is already checked out in another workspace.", "BRANCH_IN_USE", error.details);
      }
      throw error;
    }
    try {
       if (copyIgnored) {
         await copyWorktreeInclude(repositoryRoot, target, {
           maxBytes: includeMaxBytes,
           maxFiles: includeMaxFiles,
           maxTotalBytes: includeMaxTotalBytes,
         });
       }
    } catch (error) {
      await git(repositoryRoot, ["worktree", "remove", "--force", target], { acceptedExitCodes: [128] }).catch(() => {});
      throw error;
    }
    const now = this.now();
    const headResult = await git(target, ["rev-parse", "--verify", "HEAD"]);
    const record = normalizeRecord({
      id: worktreeId,
      name: worktreeName,
      root: target,
      kind: "worktree",
      managed: true,
      pinned: false,
      cleanup: lifecycle === "permanent" ? "never" : "prune",
      lifecycle: lifecycle === "permanent" ? "permanent" : "temporary",
      status: "ready",
      owner_task_id: ownerTaskId,
      owner_session_id: ownerSessionId,
      eligible_for_cleanup: false,
      repository_root: repositoryRoot,
      repo_root: repositoryRoot,
      common_dir: commonDir,
      source_id: sourceRecord?.id || "",
      base_ref: ref,
      head: headResult.stdout.trim(),
      branch: detached ? "" : branch,
      detached,
      created_at: now,
      last_used_at: now,
    }, { now, makeId: this.idFactory });
    registry.workspaces.push(record);
    try {
      await this.writeRegistry(registry);
    } catch (error) {
      await git(repositoryRoot, ["worktree", "remove", "--force", target], { acceptedExitCodes: [128] }).catch(() => {});
      throw error;
    }
    return record;
  }

  async unregister(idOrRecord, { force = false } = {}) {
    const { registry, record } = await this.resolveRecord(idOrRecord);
    if (record.kind === "worktree" && !force) fail("Managed worktrees must be removed through removeWorktree.", "PROTECTED");
    registry.workspaces = registry.workspaces.filter((entry) => entry.id !== record.id);
    await this.writeRegistry(registry);
    return record;
  }

  leasePath(recordOrId) {
    const idValue = typeof recordOrId === "string" ? recordOrId : recordOrId.id;
    if (!idPattern.test(idValue)) fail("Invalid worktree id.", "INVALID_ID");
    return join(this.leaseDirectory, leaseName(idValue));
  }

  leaseLockPath(recordOrId) {
    const idValue = typeof recordOrId === "string" ? recordOrId : recordOrId.id;
    if (!idPattern.test(idValue)) fail("Invalid worktree id.", "INVALID_ID");
    return join(this.leaseDirectory, leaseLockName(idValue));
  }

  async withLeaseLock(recordOrId, action) {
    const lockPath = this.leaseLockPath(recordOrId);
    await mkdir(dirname(lockPath), { recursive: true });
    try {
      await mkdir(lockPath);
    } catch (error) {
      if (error.code === "EEXIST") {
        const lockEntry = await lstat(lockPath).catch(() => null);
        const stale = lockEntry && Date.now() - Number(lockEntry.mtimeMs || 0) > LEASE_LOCK_STALE_MS;
        if (stale) {
          await rm(lockPath, { recursive: true, force: true }).catch(() => {});
          try {
            await mkdir(lockPath);
          } catch (retryError) {
            if (retryError.code === "EEXIST") fail("Worktree lease is busy.", "LEASED");
            throw retryError;
          }
        } else {
          fail("Worktree lease is busy.", "LEASED");
        }
      } else {
        throw error;
      }
    }
    try {
      return await action();
    } finally {
      await rm(lockPath, { recursive: true, force: true }).catch(() => {});
    }
  }

  async activeLease(recordOrId, nowMs = Date.now()) {
    const path = this.leasePath(recordOrId);
    try {
      return await this.withLeaseLock(recordOrId, async () => {
        const current = await readLease(path);
        if (current && leaseExpired(current, nowMs)) {
          await rm(path, { force: true }).catch(() => {});
          return null;
        }
        return current;
      });
    } catch (error) {
      // A concurrent acquire/renew/release is conservatively treated as an
      // active lease. Callers such as prune and remove must never mistake a
      // lease transition for an idle worktree.
      if (error?.code === "LEASED") return { locked: true };
      throw error;
    }
  }

  async acquireLease(idOrRecord, { owner = `pid:${process.pid}`, ttlMs = DEFAULT_LEASE_MS } = {}) {
    const { record } = await this.resolveRecord(idOrRecord);
    if (record.kind !== "worktree") fail("Only managed worktrees can be leased.", "INVALID_KIND");
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 1000 || ttlMs > 7 * 24 * 60 * 60 * 1000) fail("Invalid lease duration.", "INVALID_LEASE");
    return this.withLeaseLock(record, async () => {
      const path = this.leasePath(record);
      await mkdir(dirname(path), { recursive: true });
      const now = Date.now();
      const existing = await readLease(path);
      if (existing && !leaseExpired(existing, now)) {
        fail("Worktree is leased by another task.", "LEASED", existing);
      }
      if (existing) await rm(path, { force: true }).catch(() => {});
      const lease = {
        version: 1,
        worktree_id: record.id,
        owner: string(owner, `pid:${process.pid}`).slice(0, 200),
        token: this.idFactory(),
        created_at: new Date(now).toISOString(),
        expires_at: new Date(now + ttlMs).toISOString(),
        expires_at_ms: now + ttlMs,
      };
      const temporary = `${path}.${process.pid}.${this.idFactory()}.tmp`;
      await writeFile(temporary, `${JSON.stringify(lease, null, 2)}\n`, "utf8");
      try {
        await rename(temporary, path);
      } finally {
        await rm(temporary, { force: true }).catch(() => {});
      }
      return lease;
    });
  }

  async renewLease(idOrRecord, token, { ttlMs = DEFAULT_LEASE_MS } = {}) {
    const { record } = await this.resolveRecord(idOrRecord);
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 1000 || ttlMs > 7 * 24 * 60 * 60 * 1000) {
      fail("Invalid lease duration.", "INVALID_LEASE");
    }
    return this.withLeaseLock(record, async () => {
      const path = this.leasePath(record);
      const lease = await readLease(path);
      if (!lease || lease.token !== token || leaseExpired(lease)) {
        fail("Lease is missing or expired.", "LEASE_INVALID");
      }
      const now = Date.now();
      const renewed = {
        ...lease,
        expires_at: new Date(now + ttlMs).toISOString(),
        expires_at_ms: now + ttlMs,
      };
      await writeFile(path, `${JSON.stringify(renewed, null, 2)}\n`, "utf8");
      return renewed;
    });
  }

  async releaseLease(idOrRecord, token, { force = false } = {}) {
    const { record } = await this.resolveRecord(idOrRecord);
    return this.withLeaseLock(record, async () => {
      const path = this.leasePath(record);
      const lease = await readLease(path);
      if (!lease) return false;
      if (!force && lease.token !== token) fail("Lease token does not match.", "LEASE_INVALID");
      await rm(path, { force: true });
      return true;
    });
  }

  async heartbeatLease(idOrRecord, token, options = {}) {
    return this.renewLease(idOrRecord, token, options);
  }

  async pin(idOrRecord, pinned = true) {
    const { registry, record } = await this.resolveRecord(idOrRecord);
    record.pinned = Boolean(pinned);
    record.last_used_at = this.now();
    await this.writeRegistry(registry);
    return record;
  }

  async updateRecord(idOrRecord, patch = {}) {
    const { registry, record } = await this.resolveRecord(idOrRecord);
    Object.assign(record, patch);
    record.last_used_at = this.now();
    await this.writeRegistry(registry);
    return record;
  }

  async status(idOrRecord) {
    const { record } = await this.resolveRecord(idOrRecord);
    const root = await canonicalDirectory(record.root || record.path);
    const [branchResult, porcelainResult, headResult, upstreamResult] = await Promise.all([
      git(root, ["branch", "--show-current"]),
      git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
      git(root, ["rev-parse", "--verify", "HEAD"], { acceptedExitCodes: [128] }),
      git(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], { acceptedExitCodes: [128] }),
    ]);
    const changes = parsePorcelainStatus(porcelainResult.stdout);
    const upstream = upstreamResult.stdout.trim();
    let ahead = 0;
    let behind = 0;
    if (upstream && headResult.stdout.trim()) {
      const counts = await git(root, ["rev-list", "--left-right", "--count", `HEAD...${upstream}`], {
        acceptedExitCodes: [128],
      });
      const parts = counts.stdout.trim().split(/\s+/).map(Number);
      if (parts.length >= 2 && parts.every(Number.isFinite)) [ahead, behind] = parts;
    }
    const branch = branchResult.stdout.trim();
    return {
      root,
      head: headResult.stdout.trim(),
      branch: branch || "detached HEAD",
      detached: !branch,
      upstream,
      ahead,
      behind,
      conflicts: changes.filter((change) => change.conflicted).map((change) => change.path),
      renames: changes.filter((change) => change.rename || change.copy).map((change) => ({
        path: change.path,
        old_path: change.old_path,
        kind: change.rename ? "rename" : "copy",
      })),
      changes,
      revision: createHash("sha256").update(`${headResult.stdout.trim()}\0${porcelainResult.stdout}`).digest("hex"),
    };
  }

  async createSnapshot(idOrRecord, { reason = "handoff", snapshotId } = {}) {
    const { record } = await this.resolveRecord(idOrRecord);
    const root = await canonicalDirectory(record.root || record.path);
    const snapshotName = safeName(snapshotId || `${record.id}-${Date.now()}-${this.idFactory()}`);
    const snapshotRoot = join(this.dataDirectory, "snapshots", snapshotName);
    assertPathWithin(join(this.dataDirectory, "snapshots"), snapshotRoot, "INVALID_PATH");
    await mkdir(join(snapshotRoot, "files"), { recursive: true });
    const [patchResult, untrackedResult, status] = await Promise.all([
      git(root, ["diff", "--binary", "HEAD"], { acceptedExitCodes: [0, 128] }),
      git(root, ["ls-files", "--others", "--exclude-standard", "-z"]),
      this.status(record),
    ]);
    const files = untrackedResult.stdout.split("\0").filter(Boolean);
    if (files.length > DEFAULT_WORKTREE_FILES) fail("Too many untracked files for a snapshot.", "SNAPSHOT_LIMIT");
    let totalBytes = 0;
    for (const relativePath of files) {
      const source = await canonicalFile(root, relativePath, { maxBytes: DEFAULT_INCLUDE_BYTES * 16 });
      if (!source.entry.isFile()) fail(`Snapshot path is not a regular file: ${relativePath}`, "SNAPSHOT_UNSAFE");
      totalBytes += source.entry.size;
      if (totalBytes > DEFAULT_INCLUDE_TOTAL_BYTES) fail("Snapshot exceeds the total size limit.", "SNAPSHOT_LIMIT");
      const destination = join(snapshotRoot, "files", relativePath);
      await mkdir(dirname(destination), { recursive: true });
      await copyFile(source.path, destination);
    }
    const metadata = {
      version: 1,
      id: snapshotName,
      workspace_id: record.id,
      root,
      reason,
      source_head: status.head,
      source_revision: status.revision,
      source_branch: status.detached ? "" : status.branch,
      created_at: this.now(),
      untracked: files,
    };
    await writeFile(join(snapshotRoot, "changes.patch"), patchResult.stdout, "utf8");
    await writeFile(join(snapshotRoot, "metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
    return { ...metadata, path: snapshotRoot };
  }

  async restoreSnapshot(snapshot, targetIdOrRecord, {
    expected_revision = "",
    expected_head = "",
  } = {}) {
    const snapshotRoot = typeof snapshot === "object" ? snapshot.path : snapshot;
    if (typeof snapshotRoot !== "string" || !snapshotRoot) fail("A snapshot is required.", "INVALID_SNAPSHOT");
    const snapshotsRoot = join(this.dataDirectory, "snapshots");
    const canonicalSnapshot = lexicalAbsolute(snapshotRoot);
    assertPathWithin(snapshotsRoot, canonicalSnapshot, "INVALID_SNAPSHOT");
    const metadata = JSON.parse(await readFile(join(canonicalSnapshot, "metadata.json"), "utf8"));
    const { record } = await this.resolveRecord(targetIdOrRecord);
    const targetRoot = await canonicalDirectory(record.root || record.path);
    const targetStatus = await this.status(record);
    if (targetStatus.changes.length > 0) fail("Target workspace is not clean.", "HANDOFF_CONFLICT", targetStatus);
    if (expected_revision && targetStatus.revision !== expected_revision) {
      fail("Target workspace revision does not match.", "HANDOFF_CONFLICT", { current_revision: targetStatus.revision });
    }
    if (expected_head && targetStatus.head !== expected_head) {
      fail("Target workspace HEAD does not match.", "HANDOFF_CONFLICT", { current_head: targetStatus.head });
    }
    const patch = await readFile(join(canonicalSnapshot, "changes.patch"), "utf8");
    const copied = [];
    try {
      if (patch.trim()) {
        await git(targetRoot, ["apply", "--check", "--3way", join(canonicalSnapshot, "changes.patch")], { timeout: 120_000 });
        await git(targetRoot, ["apply", "--3way", join(canonicalSnapshot, "changes.patch")], { timeout: 120_000 });
      }
      const files = Array.isArray(metadata.untracked) ? metadata.untracked : [];
      for (const relativePath of files) {
        const source = await canonicalFile(join(canonicalSnapshot, "files"), relativePath, {
          maxBytes: DEFAULT_INCLUDE_BYTES * 16,
        });
        const destination = resolve(targetRoot, relativePath);
        assertPathWithin(targetRoot, destination, "SNAPSHOT_UNSAFE");
        const existing = await lstat(destination).catch(() => null);
        if (existing) fail(`Target already contains snapshot file: ${relativePath}`, "HANDOFF_CONFLICT");
        await verifyDirectoryParents(targetRoot, relativePath);
        await mkdir(dirname(destination), { recursive: true });
        await copyFile(source.path, destination);
        copied.push(destination);
      }
    } catch (error) {
      // The target was clean before the operation. Roll back the tracked
      // patch and every explicitly copied untracked path before returning a
      // conflict, so handoff is all-or-nothing.
      await git(targetRoot, ["reset", "--hard", "HEAD"], { acceptedExitCodes: [128] }).catch(() => {});
      for (const path of copied) await rm(path, { force: true }).catch(() => {});
      throw error;
    }
    return { ...metadata, applied: true, target_id: record.id };
  }

  async handoff(sourceIdOrRecord, targetIdOrRecord, options = {}) {
    const { registry: sourceRegistry, record: source } = await this.resolveRecord(sourceIdOrRecord);
    const { record: target } = await this.resolveRecord(targetIdOrRecord);
    if (source.id === target.id) fail("Source and target workspaces must differ.", "CONFLICT");
    const sourceLease = source.kind === "worktree" ? await this.activeLease(source) : null;
    const targetLease = target.kind === "worktree" ? await this.activeLease(target) : null;
    if (sourceLease || targetLease) fail("A leased workspace cannot be handed off.", "LEASED");
    const sourceStatus = await this.status(source);
    const targetStatus = await this.status(target);
    if (options.expected_revision && sourceStatus.revision !== options.expected_revision) {
      fail("Source workspace revision does not match.", "HANDOFF_CONFLICT", { current_revision: sourceStatus.revision });
    }
    if (targetStatus.changes.length > 0) fail("Target workspace is not clean.", "HANDOFF_CONFLICT", targetStatus);
    if (!sourceStatus.detached && !targetStatus.detached && sourceStatus.branch &&
      targetStatus.branch === sourceStatus.branch) {
      fail("The same branch cannot be checked out in both workspaces.", "BRANCH_IN_USE");
    }
    if (sourceStatus.branch && !sourceStatus.detached && source.repository_root) {
      const worktrees = parseWorktreeList(
        (await git(source.repository_root, ["worktree", "list", "--porcelain"])).stdout,
      );
      if (worktrees.some((entry) => !samePath(entry.path, source.root) && entry.branch === sourceStatus.branch)) {
        fail("The same branch cannot be checked out in both workspaces.", "BRANCH_IN_USE");
      }
    }
    const snapshot = await this.createSnapshot(source, { reason: "handoff" });
    const applied = await this.restoreSnapshot(snapshot, target, {
      expected_revision: options.target_expected_revision || "",
      expected_head: options.target_expected_head || "",
    });
    const targetRecord = sourceRegistry.workspaces.find((entry) => entry.id === target.id) || target;
    Object.assign(targetRecord, {
      owner_task_id: source.owner_task_id || "",
      owner_session_id: source.owner_session_id || "",
      source_id: source.id,
      status: "ready",
      last_snapshot_id: snapshot.id,
    });
    await this.writeRegistry(sourceRegistry);
    return { snapshot, ...applied, source, target: targetRecord };
  }

  async createBranch(idOrRecord, branch) {
    const { registry, record } = await this.resolveRecord(idOrRecord);
    if (record.kind !== "worktree") fail("Only managed worktrees can create branches.", "INVALID_KIND");
    if (!validBranch(branch)) fail("Invalid worktree branch.", "INVALID_BRANCH");
    if (record.branch) fail("This worktree already has a branch.", "CONFLICT");
    const existing = parseWorktreeList(
      (await git(record.repository_root || record.root, ["worktree", "list", "--porcelain"])).stdout,
    ).find((entry) => entry.branch === branch && !samePath(entry.path, record.root));
    if (existing) fail("The branch is already checked out in another workspace.", "BRANCH_IN_USE", existing);
    try {
      await git(record.root, ["switch", "-c", branch], { timeout: 120_000 });
    } catch (error) {
      if (/already exists|already checked out|is already used/i.test(error.message)) {
        fail("The branch is already checked out in another workspace.", "BRANCH_IN_USE", error.details);
      }
      throw error;
    }
    record.branch = branch;
    record.detached = false;
    record.base_ref = record.base_ref || "HEAD";
    const head = await git(record.root, ["rev-parse", "--verify", "HEAD"]);
    record.head = head.stdout.trim();
    record.status = "ready";
    record.last_used_at = this.now();
    await this.writeRegistry(registry);
    return record;
  }

  async removeWorktree(idOrRecord, { force = false, allowDirty = false } = {}) {
    const { registry, record } = await this.resolveRecord(idOrRecord);
    if (record.kind !== "worktree") return this.unregister(record);
    if (record.pinned && !force) fail("Pinned worktrees cannot be removed.", "PROTECTED");
    const lease = await this.activeLease(record);
    if (lease && !force) fail("Leased worktrees cannot be removed.", "LEASED", lease);
    const exists = await lstat(record.root).catch(() => null);
    if (exists && !force && !allowDirty && await gitDirty(record.root)) fail("Dirty worktrees cannot be removed.", "DIRTY");
    if (exists) {
      const repositoryRoot = await gitRoot(record.repository_root || record.root).catch(() => record.repository_root || record.root);
      const args = ["worktree", "remove"];
      if (force) args.push("--force");
      args.push(record.root);
      await git(repositoryRoot, args, { acceptedExitCodes: force ? [128] : [] });
      // `git worktree remove --force` normally removes the directory, but a
      // partially-created checkout can leave files behind on Windows.
      if (force) await rm(record.root, { recursive: true, force: true }).catch(() => {});
    }
    await rm(this.leasePath(record), { force: true }).catch(() => {});
    registry.workspaces = registry.workspaces.filter((entry) => entry.id !== record.id);
    await this.writeRegistry(registry);
    return record;
  }

  async recover() {
    const registry = await this.readRegistry();
    let changed = false;
    for (const record of registry.workspaces) {
      if (record.kind !== "worktree") continue;
      const exists = await lstat(record.root).catch(() => null);
      if (!exists) {
        if (record.status !== "orphaned") {
          record.status = "orphaned";
          record.last_error = "worktree path is missing";
          record.eligible_for_cleanup = false;
          changed = true;
        }
        continue;
      }
      const lease = await this.activeLease(record);
      if (!lease && record.status === "busy") {
        record.status = "ready";
        // A recovered busy worktree may contain an incomplete task. Keep it
        // out of automatic pruning until the caller explicitly archives it.
        record.eligible_for_cleanup = false;
        record.last_error = record.last_error || "stale lease recovered";
        changed = true;
      }
    }
    if (changed) await this.writeRegistry(registry);
    return registry;
  }

  async prune({ maxAgeMs = 0, nowMs = Date.now(), limit = DEFAULT_WORKTREE_LIMIT, force = false } = {}) {
    if (!Number.isSafeInteger(maxAgeMs) || maxAgeMs < 0) fail("Invalid prune age.", "INVALID_PRUNE");
    if (!Number.isSafeInteger(limit) || limit < 0 || limit > 1000) fail("Invalid prune limit.", "INVALID_PRUNE");
    const registry = await this.readRegistry();
    const removed = [];
    const skipped = [];
    const candidates = registry.workspaces
      .filter((record) => record.kind === "worktree" && !record.pinned &&
        record.cleanup !== "never" && record.lifecycle !== "permanent" &&
        record.eligible_for_cleanup && record.status === "ready")
      .sort((a, b) => a.last_used_at.localeCompare(b.last_used_at));
    const excess = Math.max(0, candidates.length - limit);
    for (const record of candidates) {
      if (record.kind !== "worktree" || record.pinned || record.cleanup === "never" ||
        record.lifecycle === "permanent" || !record.eligible_for_cleanup || record.status !== "ready") continue;
      const lease = await this.activeLease(record, nowMs);
      if (lease) {
        skipped.push({ id: record.id, reason: "leased" });
        continue;
      }
      const age = nowMs - new Date(record.last_used_at).getTime();
      const exists = await lstat(record.root).catch(() => null);
      if (exists && age < maxAgeMs && removed.length >= excess) continue;
      if (removed.length >= excess && maxAgeMs === 0) continue;
      try {
        await this.removeWorktree(record, { force, allowDirty: force });
        removed.push(record.id);
      } catch (error) {
        skipped.push({ id: record.id, reason: error.code || error.message });
      }
    }
    const repositories = new Set(
      registry.workspaces.filter((record) => record.kind === "worktree" && record.repository_root).map((record) => record.repository_root),
    );
    for (const repository of repositories) await git(repository, ["worktree", "prune"], { acceptedExitCodes: [128] }).catch(() => {});
    return { removed, skipped };
  }
}

export async function createWorktree(options = {}) {
  return new WorktreeManager(options.manager || options).createWorktree(options);
}

export async function removeWorktree(id, options = {}) {
  const manager = options.manager || new WorktreeManager(options);
  return manager.removeWorktree(id, options);
}

export async function pruneWorktrees(options = {}) {
  return new WorktreeManager(options.manager || options).prune(options);
}

export async function createWorkspaceSnapshot(id, options = {}) {
  const manager = options.manager || new WorktreeManager(options);
  return manager.createSnapshot(id, options);
}

export async function restoreWorkspaceSnapshot(snapshot, target, options = {}) {
  const manager = options.manager || new WorktreeManager(options);
  return manager.restoreSnapshot(snapshot, target, options);
}
