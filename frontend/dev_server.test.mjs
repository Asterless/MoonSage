import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { appendFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { PassThrough } from "node:stream";
import { promisify } from "node:util";

import { applyBatchEvent, buildAgentPrompt, eventForAgentOutput, eventForBatchOutput, isTrustedRequest, killProcessTree, metaForConversation, normalizeBatchConfig, normalizeLineEndings, parseAgentEvents, parseGitStatus, requireJsonContentType, resolveRequestPath, resolveWorkspacePath, runBatchWorker, serve, verifiedWorkspacePath, workspaceRelativePath } from "./dev_server.mjs";
import { WorktreeManager, migrateRegistry } from "./worktree_manager.mjs";

const execFileAsync = promisify(execFile);

let canSpawnChildren = true;
try {
  await execFileAsync("git", ["--version"]);
} catch {
  canSpawnChildren = false;
}

async function closeServer(server) {
  server.closeAllConnections();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

async function waitForBatch(base, id, predicate, timeout = 3000) {
  const deadline = Date.now() + timeout;
  let batch = null;
  while (Date.now() < deadline) {
    const response = await fetch(`${base}/api/batches/${id}`);
    if (response.ok) {
      batch = (await response.json()).batch;
      if (predicate(batch)) return batch;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(`batch ${id} did not reach the expected state: ${JSON.stringify(batch)}`);
}

async function persistFakeBatchEvent(batch, context, emit, event) {
  const canonical = event.kind ? event : {
    kind: event.type,
    batch_id: batch.id,
    item_key: event.item_id || event.item_key || event.item?.id || event.item?.key || "",
    cycle: Number.isInteger(event.cycle) ? event.cycle : batch.cycle,
    timestamp_ms: Date.now(),
    message: event.message || "",
    data: Object.fromEntries(Object.entries(event).filter(([key]) => ![
      "type", "item_id", "item_key", "cycle", "message",
    ].includes(key))),
  };
  applyBatchEvent(batch, canonical);
  await writeFile(context.paths.meta, JSON.stringify(batch, null, 2) + "\n", "utf8");
  await appendFile(context.paths.events, JSON.stringify(canonical) + "\n", "utf8");
  emit(canonical);
}

async function runGitCommand(cwd, args, { allowFailure = false } = {}) {
  try {
    const result = await execFileAsync("git", args, {
      cwd,
      encoding: "utf8",
      windowsHide: true,
      maxBuffer: 2 * 1024 * 1024,
    });
    return { code: 0, stdout: String(result.stdout || ""), stderr: String(result.stderr || "") };
  } catch (error) {
    if (!allowFailure) throw error;
    return {
      code: Number(error.code),
      stdout: String(error.stdout || ""),
      stderr: String(error.stderr || ""),
    };
  }
}

async function createGitFixture(prefix = "moonsage-worktree-repo-") {
  const repository = await mkdtemp(join(tmpdir(), prefix));
  await runGitCommand(repository, ["init", "-q"]);
  await runGitCommand(repository, ["config", "user.email", "test@moonsage.local"]);
  await runGitCommand(repository, ["config", "user.name", "MoonSage Tests"]);
  await writeFile(join(repository, ".gitignore"), ".env.local\n.worktreeinclude\n", "utf8");
  await writeFile(join(repository, "README.md"), "fixture\n", "utf8");
  await runGitCommand(repository, ["add", ".gitignore", "README.md"]);
  await runGitCommand(repository, ["commit", "-qm", "fixture"]);
  return repository;
}

test("resolves files inside the workspace", () => {
  assert.equal(resolveRequestPath("/frontend/index.html"), join(import.meta.dirname, "index.html"));
});

test("rejects encoded parent traversal", () => {
  assert.equal(resolveRequestPath("/%2e%2e%2fsecret.txt"), null);
});

test("rejects Windows backslash traversal", { skip: process.platform !== "win32" }, () => {
  assert.equal(resolveRequestPath("/%2e%2e%5cmooncake-secret%5cx"), null);
});

test("rejects malformed URL encoding", () => {
  assert.equal(resolveRequestPath("/frontend/%zz"), null);
});

test("resolves only relative workspace paths", () => {
  const workspace = join(tmpdir(), "moonsage-workspace");
  assert.equal(resolveWorkspacePath(workspace, "src/main.mbt"), join(workspace, "src/main.mbt"));
  assert.equal(resolveWorkspacePath(workspace, "../secret.txt"), null);
  assert.equal(resolveWorkspacePath(workspace, "/absolute.txt"), null);
  assert.equal(resolveWorkspacePath(workspace, ".env"), null);
  assert.equal(resolveWorkspacePath(workspace, ".ENV"), null);
  assert.equal(resolveWorkspacePath(workspace, ".git/config"), null);
  assert.equal(resolveWorkspacePath(workspace, ".GIT/config"), null);
  assert.equal(resolveWorkspacePath(workspace, ".mooncakes/cache.json"), null);
  assert.equal(resolveWorkspacePath(workspace, ".moonsage/sessions/private.json"), null);
  assert.equal(resolveWorkspacePath(workspace, ".cache/results.json"), null);
  assert.equal(resolveWorkspacePath(workspace, "_build/output.js"), null);
  assert.equal(resolveWorkspacePath(workspace, "_build.bak/output.js"), null);
  assert.equal(resolveWorkspacePath(workspace, "node_modules/package/index.js"), null);
  assert.equal(resolveWorkspacePath(workspace, "target/debug/output"), null);
  assert.equal(resolveWorkspacePath(workspace, "_audit_ws_MoonQOI3/report.md"), null);
  assert.equal(resolveWorkspacePath(workspace, "_AUDIT_WS_MoonQOI3/report.md"), null);
  if (process.platform === "win32") {
    assert.equal(resolveWorkspacePath(workspace, "C:/Windows/System32/config"), null);
  }
});

test("workspace tree and file access consistently ignore generated directories", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-filtered-workspace-"));
  const ignoredDirectories = [
    ".git",
    ".mooncakes",
    ".moonsage",
    ".cache",
    "_build",
    "_build.bak",
    "node_modules",
    "target",
    "_audit_ws_example",
  ];
  await mkdir(join(workspaceRoot, "src"));
  await writeFile(join(workspaceRoot, "src", "main.mbt"), "fn main {}\n", "utf8");
  await writeFile(join(workspaceRoot, ".env"), "SECRET=hidden\n", "utf8");
  for (const directory of ignoredDirectories) {
    await mkdir(join(workspaceRoot, directory), { recursive: true });
    await writeFile(join(workspaceRoot, directory, "hidden.mbt"), "let hidden = true\n", "utf8");
  }
  let linkedIgnoredPath = "";
  try {
    await symlink(
      join(workspaceRoot, ".git"),
      join(workspaceRoot, "metadata"),
      process.platform === "win32" ? "junction" : "dir",
    );
    linkedIgnoredPath = "metadata/hidden.mbt";
  } catch (error) {
    if (!["EACCES", "ENOTSUP", "EPERM"].includes(error.code)) throw error;
  }

  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  try {
    const treeResponse = await fetch(`http://127.0.0.1:${port}/api/workspace/tree`);
    assert.equal(treeResponse.status, 200);
    const tree = await treeResponse.json();
    assert.deepEqual(tree.files, ["src/main.mbt"]);
    assert.equal(tree.truncated, false);

    const readable = await fetch(
      `http://127.0.0.1:${port}/api/workspace/file?path=src%2Fmain.mbt`,
    );
    assert.equal(readable.status, 200);
    assert.match((await readable.json()).content, /fn main/);

    for (const directory of ignoredDirectories) {
      const path = encodeURIComponent(`${directory}/hidden.mbt`);
      const response = await fetch(`http://127.0.0.1:${port}/api/workspace/file?path=${path}`);
      assert.equal(response.status, 400, directory);
    }
    const envResponse = await fetch(`http://127.0.0.1:${port}/api/workspace/file?path=.env`);
    assert.equal(envResponse.status, 400);
    const mixedCaseResponse = await fetch(
      `http://127.0.0.1:${port}/api/workspace/file?path=.GIT%2Fhidden.mbt`,
    );
    assert.equal(mixedCaseResponse.status, 400);
    if (linkedIgnoredPath) {
      const linkedResponse = await fetch(
        `http://127.0.0.1:${port}/api/workspace/file?path=${encodeURIComponent(linkedIgnoredPath)}`,
      );
      assert.equal(linkedResponse.status, 400);
    }
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("parses staged, unstaged, and untracked git status", () => {
  assert.deepEqual(parseGitStatus("M  staged.mbt\0 M working.mbt\0?? new.mbt\0"), [
    { path: "staged.mbt", old_path: "", index: "M", worktree: " ", staged: true, unstaged: false, untracked: false, conflicted: false, rename: false, copy: false },
    { path: "working.mbt", old_path: "", index: " ", worktree: "M", staged: false, unstaged: true, untracked: false, conflicted: false, rename: false, copy: false },
    { path: "new.mbt", old_path: "", index: "?", worktree: "?", staged: false, unstaged: true, untracked: true, conflicted: false, rename: false, copy: false },
  ]);
});

test("migrates v1 workspace records to local v2 records", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-v1-workspace-"));
  try {
    const result = migrateRegistry({
      version: 1,
      workspaces: [{
        id: "legacy-123456",
        name: "legacy",
        path: workspaceRoot,
        created_at: "2025-01-01T00:00:00.000Z",
        last_used_at: "2025-01-02T00:00:00.000Z",
      }],
    }, { now: "2026-01-01T00:00:00.000Z" });
    assert.equal(result.migrated, true);
    assert.equal(result.from_version, 1);
    assert.equal(result.registry.version, 2);
    const record = result.registry.workspaces[0];
    const expected = {
      id: "legacy-123456",
      name: "legacy",
      root: workspaceRoot,
      path: workspaceRoot,
      kind: "local",
      managed: false,
      created_at: "2025-01-01T00:00:00.000Z",
      last_used_at: "2025-01-02T00:00:00.000Z",
      pinned: true,
      cleanup: "never",
      repo_root: "",
      repository_root: "",
      common_dir: "",
      source_id: "",
      base_ref: "",
      head: "",
      branch: "",
      detached: false,
      lifecycle: "local",
      status: "ready",
      owner_task_id: "",
      owner_session_id: "",
      eligible_for_cleanup: false,
      last_error: "",
    };
    for (const [key, value] of Object.entries(expected)) assert.deepEqual(record[key], value, key);
  } finally {
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("creates detached managed worktrees and copies only .worktreeinclude files", async () => {
  const repository = await createGitFixture();
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-worktree-data-"));
  const manager = new WorktreeManager({ dataDirectory: dataRoot });
  try {
    await writeFile(join(repository, ".env.local"), "LOCAL_ONLY=1\n", "utf8");
    await writeFile(join(repository, ".worktreeinclude"), "# explicit ignored files\n.env.local\n", "utf8");
    const record = await manager.createWorktree({ sourceRoot: repository });
    assert.equal(record.kind, "worktree");
    assert.equal(record.detached, true);
    assert.equal(record.branch, "");
    assert.equal(record.lifecycle, "temporary");
    assert.equal(record.repository_root, repository);
    assert.match(record.root, /worktrees/);
    assert.equal(await readFile(join(record.root, ".env.local"), "utf8"), "LOCAL_ONLY=1\n");
    const symbolicHead = await runGitCommand(record.root, ["symbolic-ref", "--short", "-q", "HEAD"], { allowFailure: true });
    assert.equal(symbolicHead.code, 1);
    assert.equal(symbolicHead.stdout.trim(), "");
    const worktreeList = await runGitCommand(repository, ["worktree", "list", "--porcelain"]);
    const listedRoot = record.root.replaceAll("\\", "/").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    assert.match(worktreeList.stdout, new RegExp(`worktree ${listedRoot}`));
    await manager.removeWorktree(record, { force: true });
    assert.equal(await manager.readRegistry().then((registry) => registry.workspaces.some((entry) => entry.id === record.id)), false);
  } finally {
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("rolls back a worktree when .worktreeinclude validation fails", async () => {
  const repository = await createGitFixture("moonsage-worktree-rollback-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-worktree-rollback-data-"));
  const manager = new WorktreeManager({ dataDirectory: dataRoot });
  try {
    await writeFile(join(repository, ".too-large"), Buffer.alloc(32, 0x41));
    await writeFile(join(repository, ".worktreeinclude"), ".too-large\n", "utf8");
    await assert.rejects(
      manager.createWorktree({ sourceRoot: repository, includeMaxBytes: 8 }),
      (error) => error?.code === "UNSAFE_INCLUDE",
    );
    const registry = await manager.readRegistry();
    assert.equal(registry.workspaces.length, 0);
    const worktrees = await runGitCommand(repository, ["worktree", "list", "--porcelain"]);
    assert.equal((worktrees.stdout.match(/^worktree /gm) || []).length, 1);
    await assert.rejects(
      manager.createWorktree({ sourceRoot: repository, name: "../invalid" }),
      (error) => error?.code === "INVALID_NAME",
    );
    const afterInvalidName = await runGitCommand(repository, ["worktree", "list", "--porcelain"]);
    assert.equal((afterInvalidName.stdout.match(/^worktree /gm) || []).length, 1);
  } finally {
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("uses an atomic lease and recovers expired leases after restart", async () => {
  const repository = await createGitFixture("moonsage-lease-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-lease-data-"));
  const managerA = new WorktreeManager({ dataDirectory: dataRoot });
  const managerB = new WorktreeManager({ dataDirectory: dataRoot });
  let record;
  try {
    record = await managerA.createWorktree({ sourceRoot: repository });
    const attempts = await Promise.allSettled([
      managerA.acquireLease(record, { owner: "task-a", ttlMs: 5_000 }),
      managerB.acquireLease(record, { owner: "task-b", ttlMs: 5_000 }),
    ]);
    assert.equal(attempts.filter((attempt) => attempt.status === "fulfilled").length, 1);
    assert.equal(attempts.filter((attempt) => attempt.status === "rejected").length, 1);
    const rejected = attempts.find((attempt) => attempt.status === "rejected");
    assert.equal(rejected.reason.code, "LEASED");
    const lease = attempts.find((attempt) => attempt.status === "fulfilled").value;
    await managerA.releaseLease(record, lease.token);
    const reacquired = await managerB.acquireLease(record, { owner: "task-c", ttlMs: 5_000 });
    const leasePath = managerB.leasePath(record);
    const expired = { ...reacquired, expires_at_ms: Date.now() - 1, expires_at: new Date(Date.now() - 1).toISOString() };
    await writeFile(leasePath, JSON.stringify(expired) + "\n", "utf8");
    assert.equal(await managerA.activeLease(record), null);
    await managerA.updateRecord(record.id, { status: "busy", eligible_for_cleanup: false });
    const recovered = await managerB.recover();
    const restored = recovered.workspaces.find((entry) => entry.id === record.id);
    assert.equal(restored.status, "ready");
    assert.equal(restored.eligible_for_cleanup, false);
  } finally {
    if (record) await managerA.removeWorktree(record, { force: true }).catch(() => {});
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("handoff rejects a dirty target without leaving a partial patch", async () => {
  const repository = await createGitFixture("moonsage-handoff-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-handoff-data-"));
  const manager = new WorktreeManager({ dataDirectory: dataRoot });
  let source;
  let target;
  try {
    source = await manager.createWorktree({ sourceRoot: repository });
    target = await manager.createWorktree({ sourceRoot: repository });
    await manager.createBranch(source.id, "handoff-source");
    await writeFile(join(source.root, "README.md"), "fixture\nsource change\n", "utf8");
    await writeFile(join(target.root, "README.md"), "fixture\ntarget change\n", "utf8");
    await assert.rejects(
      manager.handoff(source.id, target.id),
      (error) => error?.code === "HANDOFF_CONFLICT",
    );
    assert.equal((await readFile(join(target.root, "README.md"), "utf8")).replaceAll("\r\n", "\n"), "fixture\ntarget change\n");
    await runGitCommand(target.root, ["restore", "README.md"]);
    const transferred = await manager.handoff(source.id, target.id);
    assert.equal(transferred.applied, true);
    assert.equal((await readFile(join(target.root, "README.md"), "utf8")).replaceAll("\r\n", "\n"), "fixture\nsource change\n");
    assert.ok(transferred.snapshot?.id);
  } finally {
    if (source) await manager.removeWorktree(source, { force: true }).catch(() => {});
    if (target) await manager.removeWorktree(target, { force: true }).catch(() => {});
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("prune keeps pinned, permanent, leased, and ineligible worktrees", async () => {
  const repository = await createGitFixture("moonsage-prune-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-prune-data-"));
  const manager = new WorktreeManager({ dataDirectory: dataRoot });
  const records = [];
  try {
    const removable = await manager.createWorktree({ sourceRoot: repository });
    const pinned = await manager.createWorktree({ sourceRoot: repository });
    const permanent = await manager.createWorktree({ sourceRoot: repository, lifecycle: "permanent" });
    const ineligible = await manager.createWorktree({ sourceRoot: repository });
    const leased = await manager.createWorktree({ sourceRoot: repository });
    records.push(removable, pinned, permanent, ineligible, leased);
    await manager.updateRecord(removable.id, { eligible_for_cleanup: true });
    await manager.pin(pinned.id, true);
    await manager.updateRecord(ineligible.id, { eligible_for_cleanup: false });
    await manager.updateRecord(leased.id, { eligible_for_cleanup: true });
    await manager.acquireLease(leased, { owner: "prune-test", ttlMs: 5_000 });
    const result = await manager.prune({ limit: 0 });
    assert.ok(result.removed.includes(removable.id));
    assert.ok(result.skipped.some((entry) => entry.id === leased.id && entry.reason === "leased"));
    const remaining = await manager.readRegistry();
    assert.equal(remaining.workspaces.some((entry) => entry.id === removable.id), false);
    for (const [label, protectedRecord] of [["pinned", pinned], ["permanent", permanent], ["ineligible", ineligible], ["leased", leased]]) {
      assert.equal(remaining.workspaces.some((entry) => entry.id === protectedRecord.id), true, `${label}:${protectedRecord.id}`);
    }
  } finally {
    for (const record of records) await manager.removeWorktree(record, { force: true }).catch(() => {});
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("workspace file saves reject stale revisions with a 409", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-revision-workspace-"));
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-revision-data-"));
  await writeFile(join(workspaceRoot, "note.txt"), "before\n", "utf8");
  const server = serve({ listenPort: 0, workspaceRoot, workspaceDataDirectory: dataRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    const loaded = await fetch(`${base}/api/workspace/file?path=note.txt`);
    assert.equal(loaded.status, 200);
    const document = await loaded.json();
    assert.equal(document.content, "before\n");
    assert.match(document.revision, /^[0-9a-f]{64}$/);
    await writeFile(join(workspaceRoot, "note.txt"), "external\n", "utf8");
    const stale = await fetch(`${base}/api/workspace/file`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: "note.txt", content: "overwrite\n", expected_revision: document.revision }),
    });
    assert.equal(stale.status, 409);
    const conflict = await stale.json();
    assert.match(conflict.current_revision, /^[0-9a-f]{64}$/);
    assert.equal(await readFile(join(workspaceRoot, "note.txt"), "utf8"), "external\n");
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("workspace API creates, lists, and removes a detached managed worktree", async () => {
  const repository = await createGitFixture("moonsage-worktree-api-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-worktree-api-data-"));
  await writeFile(join(repository, ".env.local"), "API_ONLY=1\n", "utf8");
  await writeFile(join(repository, ".worktreeinclude"), ".env.local\n", "utf8");
  const server = serve({ listenPort: 0, workspaceRoot: repository, workspaceDataDirectory: dataRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  let createdId = "";
  try {
    const registered = await fetch(`${base}/api/workspaces`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: repository }),
    });
    assert.equal(registered.status, 201);
    const source = (await registered.json()).workspace;
    const created = await fetch(`${base}/api/workspaces/${source.id}/worktree`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ copy_ignored: true }),
    });
    assert.equal(created.status, 201);
    const workspace = (await created.json()).workspace;
    createdId = workspace.id;
    assert.equal(workspace.kind, "worktree");
    assert.equal(workspace.managed, true);
    assert.equal(workspace.detached, true);
    assert.equal(workspace.branch, "");
    assert.equal(await readFile(join(workspace.path, ".env.local"), "utf8"), "API_ONLY=1\n");
    const listed = await (await fetch(`${base}/api/workspaces`)).json();
    assert.ok(listed.workspaces.some((entry) => entry.id === createdId && entry.kind === "worktree"));
    const removed = await fetch(`${base}/api/workspaces/${createdId}`, { method: "DELETE" });
    assert.equal(removed.status, 200);
    assert.equal((await (await fetch(`${base}/api/workspaces`)).json()).workspaces.some((entry) => entry.id === createdId), false);
  } finally {
    if (createdId) {
      await fetch(`${base}/api/workspaces/${createdId}`, { method: "DELETE" }).catch(() => {});
    }
    await closeServer(server);
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("builds a bounded conversation transcript", () => {
  const prompt = buildAgentPrompt([
    { role: "user", text: "你好" },
    { role: "assistant", text: "你好，有什么可以帮你？" },
    { role: "user", text: "找一个 HTTP 客户端" },
  ]);
  assert.match(prompt, /CONVERSATION HISTORY:\nUser:\n你好/);
  assert.match(prompt, /Assistant:\n你好，有什么可以帮你？/);
  assert.match(prompt, /CURRENT USER REQUEST:\n找一个 HTTP 客户端/);

  const longPrompt = buildAgentPrompt(Array.from({ length: 45 }, (_, index) => ({
    role: "user",
    text: `message-${index}`,
  })));
  assert.doesNotMatch(longPrompt, /message-0\n/);
  assert.match(longPrompt, /CURRENT USER REQUEST:\nmessage-44/);

  const onboardingPrompt = buildAgentPrompt([
    { role: "assistant", text: "界面欢迎文案" },
    { role: "user", text: "实际问题" },
  ]);
  assert.doesNotMatch(onboardingPrompt, /界面欢迎文案/);
  assert.match(onboardingPrompt, /CURRENT USER REQUEST:\n实际问题/);
});

test("collects final agent deltas and surfaces errors", () => {
  assert.deepEqual(parseAgentEvents([
    '{"type":"final_started"}',
    '{"type":"final_delta","text":"Hello "}',
    '{"type":"final_delta","text":"world"}',
  ].join("\n")), { answer: "Hello world" });
  assert.deepEqual(parseAgentEvents('{"type":"error","message":"missing key"}'), {
    error: "missing key",
  });
});

test("validates and passes canonical agent events through unchanged", () => {
  assert.deepEqual(eventForAgentOutput('{"type":"thinking_delta","round":1,"text":"private"}'), {
    type: "thinking_delta",
    round: 1,
    text: "private",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"tool_started","round":1,"call_id":"c1","name":"search","arguments":"{}"}'), {
    type: "tool_started",
    round: 1,
    call_id: "c1",
    name: "search",
    arguments: "{}",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"final_delta","text":"答案"}'), {
    type: "final_delta",
    text: "答案",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"final_started"}'), {
    type: "final_started",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"error","message":"missing key"}'), {
    type: "error",
    message: "missing key",
  });
  assert.equal(eventForAgentOutput('{"type":"thinking_delta","text":"missing round"}'), null);
  assert.equal(eventForAgentOutput('{"type":"delta","text":"legacy alias"}'), null);
  assert.equal(eventForAgentOutput("null"), null);
});

test("serves the Agent API without exposing model credentials", async () => {
  let received = [];
  const server = serve({
    listenPort: 0,
    agentRunner: async (messages) => {
      received = messages;
      return { answer: "来自 Agent 的回答" };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/agent`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        session_id: "session-1",
        messages: [{ role: "user", text: "你好" }],
      }),
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/x-ndjson; charset=utf-8");
    assert.deepEqual((await response.text()).trim().split("\n").map(JSON.parse), [
      { type: "meta", history_truncated: false },
      { type: "status", message: "正在启动 Agent" },
      { type: "final_started" },
      { type: "final_delta", text: "来自 Agent 的回答" },
      { type: "done" },
    ]);
    assert.deepEqual(received, [{ role: "user", text: "你好" }]);

    const methodResponse = await fetch(`http://127.0.0.1:${port}/api/agent`);
    assert.equal(methodResponse.status, 405);

    const crossSiteResponse = await fetch(`http://127.0.0.1:${port}/api/agent`, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: JSON.stringify({ messages: [{ role: "user", text: "你好" }] }),
    });
    assert.equal(crossSiteResponse.status, 415);

    const pageResponse = await fetch(`http://127.0.0.1:${port}/frontend/`);
    assert.equal(pageResponse.status, 200);
  } finally {
    await closeServer(server);
  }
});

test("streams answer deltas before the agent process finishes", async () => {
  let finishAgent;
  const server = serve({
    listenPort: 0,
    agentRunner: async (_messages, emit) => {
      emit({ type: "final_started" });
      emit({ type: "final_delta", text: "第一段" });
      await new Promise((resolve) => { finishAgent = resolve; });
      return { answer: "第一段第二段" };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/agent`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", text: "你好" }] }),
    });
    const reader = response.body.getReader();
    const firstChunk = new TextDecoder().decode((await reader.read()).value);
    assert.match(firstChunk, /"type":"status","message":"正在启动 Agent"/);
    assert.match(firstChunk, /"type":"final_delta","text":"第一段"/);
    finishAgent();
    await reader.cancel();
  } finally {
    await closeServer(server);
  }
});

test("workspace API edits files and completes a git workflow", { skip: !canSpawnChildren }, async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-workspace-"));
  await execFileAsync("git", ["init"], { cwd: workspaceRoot });
  await execFileAsync("git", ["config", "user.name", "MoonSage Test"], { cwd: workspaceRoot });
  await execFileAsync("git", ["config", "user.email", "test@moonsage.local"], { cwd: workspaceRoot });
  await writeFile(join(workspaceRoot, "main.mbt"), "fn main {\n  println(1)\n}\n", "utf8");
  await writeFile(join(workspaceRoot, ".env"), "SECRET=hidden\n", "utf8");
  await mkdir(join(workspaceRoot, ".moonsage"));
  await writeFile(join(workspaceRoot, ".moonsage", "session.json"), "{}\n", "utf8");
  await execFileAsync("git", ["add", "main.mbt"], { cwd: workspaceRoot });
  await execFileAsync("git", ["commit", "-m", "initial"], { cwd: workspaceRoot });
  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const api = "http://127.0.0.1:" + port + "/api/workspace";
  try {
    const tree = await (await fetch(api + "/tree")).json();
    assert.deepEqual(tree.files, ["main.mbt"]);

    const opened = await (await fetch(api + "/file?path=main.mbt")).json();
    assert.match(opened.content, /println\(1\)/);

    const saved = await fetch(api + "/file", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: "main.mbt", content: "fn main {\n  println(2)\n}\n" }),
    });
    assert.equal(saved.status, 200);
    assert.match(await readFile(join(workspaceRoot, "main.mbt"), "utf8"), /println\(2\)/);

    await writeFile(join(workspaceRoot, "new.mbt"), "let answer = 42\n", "utf8");
    const status = await (await fetch(api + "/git/status")).json();
    assert.equal(status.changes.length, 2);

    const workingDiff = await (await fetch(api + "/git/diff?scope=working")).json();
    assert.match(workingDiff.diff, /println\(2\)/);
    assert.match(workingDiff.diff, /new\.mbt/);

    const stage = await fetch(api + "/git/stage", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ paths: ["main.mbt", "new.mbt"] }),
    });
    assert.equal(stage.status, 200);
    const stagedDiff = await (await fetch(api + "/git/diff?scope=staged")).json();
    assert.match(stagedDiff.diff, /println\(2\)/);
    assert.match(stagedDiff.diff, /new\.mbt/);

    const unstage = await fetch(api + "/git/unstage", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ paths: ["new.mbt"] }),
    });
    assert.equal(unstage.status, 200);
    await fetch(api + "/git/stage", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ paths: ["new.mbt"] }),
    });

    const commit = await fetch(api + "/git/commit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: "update workspace" }),
    });
    const committed = await commit.json();
    assert.equal(commit.status, 200, committed.error);
    assert.deepEqual(committed.changes, []);

    const traversal = await fetch(api + "/file?path=../secret.txt");
    assert.equal(traversal.status, 400);
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("workspace API unstages files before the first commit", { skip: !canSpawnChildren }, async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-unborn-"));
  await execFileAsync("git", ["init"], { cwd: workspaceRoot });
  await writeFile(join(workspaceRoot, "first.mbt"), "let answer = 42\n", "utf8");
  await execFileAsync("git", ["add", "first.mbt"], { cwd: workspaceRoot });
  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const api = "http://127.0.0.1:" + port + "/api/workspace";
  try {
    const response = await fetch(api + "/git/unstage", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ paths: ["first.mbt"] }),
    });
    const status = await response.json();
    assert.equal(response.status, 200, status.error);
    assert.equal(status.changes.length, 1);
    assert.equal(status.changes[0].path, "first.mbt");
    assert.equal(status.changes[0].staged, false);
    assert.equal(status.changes[0].untracked, true);
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("workspace path policy rejects traversal, ignored entries, and symlinks", { skip: process.platform === "win32" }, async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-path-policy-"));
  const outsideRoot = await mkdtemp(join(tmpdir(), "moonsage-path-outside-"));
  try {
    await writeFile(join(outsideRoot, "secret.txt"), "secret\n", "utf8");
    await symlink(join(outsideRoot, "secret.txt"), join(workspaceRoot, "link.txt"));
    assert.equal(workspaceRelativePath("../secret.txt"), null);
    assert.equal(workspaceRelativePath(".git/config"), null);
    assert.equal(workspaceRelativePath("_audit_ws_123/log.txt"), null);
    assert.equal(workspaceRelativePath("src\\main.mbt"), "src/main.mbt");
    await assert.rejects(
      verifiedWorkspacePath(workspaceRoot, "link.txt"),
      /Symbolic links are not supported/,
    );
  } finally {
    await rm(workspaceRoot, { recursive: true, force: true });
    await rm(outsideRoot, { recursive: true, force: true });
  }
});

test("static serving only exposes the frontend and built JS", () => {
  assert.equal(resolveRequestPath("/frontend/index.html"), join(import.meta.dirname, "index.html"));
  assert.equal(resolveRequestPath("/.env"), null);
  assert.equal(resolveRequestPath("/.git/config"), null);
  assert.equal(resolveRequestPath("/moon.mod"), null);
  assert.equal(resolveRequestPath("/moonsage_test.mbt"), null);
  assert.equal(
    resolveRequestPath("/_build/js/release/build/frontend/frontend.js"),
    join(import.meta.dirname, "..", "_build", "js", "release", "build", "frontend", "frontend.js"),
  );
});

test("serves local SVG assets with the SVG content type", async () => {
  const server = serve({ listenPort: 0 });
  try {
    await new Promise((resolve) => server.once("listening", resolve));
    const { port } = server.address();
    const response = await fetch(
      `http://127.0.0.1:${port}/frontend/assets/icons/menu.svg`,
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/svg+xml");
    const icon = await response.text();
    assert.match(icon, /@license lucide-static/);
    assert.match(icon, /lucide-menu/);
  } finally {
    await closeServer(server);
  }
});

test("accepts only loopback hosts and same-origin pages", () => {
  const fake = (headers) => ({ headers });
  assert.equal(isTrustedRequest(fake({ host: "127.0.0.1:8765" }), 8765), true);
  assert.equal(isTrustedRequest(fake({ host: "localhost:8765" }), 8765), true);
  assert.equal(isTrustedRequest(fake({ host: "evil.example:8765" }), 8765), false);
  assert.equal(
    isTrustedRequest(fake({ host: "127.0.0.1:8765", origin: "http://127.0.0.1:8765" }), 8765),
    true,
  );
  assert.equal(
    isTrustedRequest(fake({ host: "127.0.0.1:8765", origin: "http://evil.example" }), 8765),
    false,
  );
});

test("workspace write endpoints require application/json", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-csrf-"));
  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const api = "http://127.0.0.1:" + port + "/api/workspace";
  try {
    assert.equal(requireJsonContentType({ headers: { "content-type": "application/json; charset=utf-8" } }), true);
    assert.equal(requireJsonContentType({ headers: { "content-type": "text/plain" } }), false);
    assert.equal(requireJsonContentType({ headers: {} }), false);

    const csrfResponse = await fetch(api + "/git/commit", {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: JSON.stringify({ message: "forged" }),
    });
    assert.equal(csrfResponse.status, 415);

    const forgedHost = await new Promise((resolve) => {
      const request = http.request(
        { host: "127.0.0.1", port, path: "/api/workspace/git/status", method: "GET", agent: false, headers: { Host: "evil.example" } },
        (response) => {
          response.resume();
          resolve(response.statusCode);
        },
      );
      request.on("error", () => resolve(null));
      request.end();
    });
    assert.equal(forgedHost, 403);
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("passes rich canonical lifecycle events through and caps tool results", () => {
  const args = JSON.stringify({ query: "http client" });
  assert.deepEqual(
    eventForAgentOutput(JSON.stringify({ type: "tool_started", round: 1, call_id: "c1", name: "search_modules", arguments: args })),
    { type: "tool_started", round: 1, call_id: "c1", name: "search_modules", arguments: args },
  );
  assert.deepEqual(
    eventForAgentOutput(JSON.stringify({ type: "tool_finished", round: 1, call_id: "c1", name: "search_modules", status: "ok", result: "x".repeat(5000) })),
    { type: "tool_finished", round: 1, call_id: "c1", name: "search_modules", status: "ok", result: "x".repeat(4096) },
  );
  assert.deepEqual(eventForAgentOutput(JSON.stringify({ type: "retrying", attempt: 2, reason: "429" })), {
    type: "retrying", attempt: 2, reason: "429",
  });
  assert.deepEqual(eventForAgentOutput(JSON.stringify({ type: "warning", message: "budget low" })), {
    type: "warning", message: "budget low",
  });
  assert.deepEqual(eventForAgentOutput(JSON.stringify({ type: "thinking_delta", round: 2, text: "考虑中" })), {
    type: "thinking_delta", round: 2, text: "考虑中",
  });
  const multibyte = eventForAgentOutput(JSON.stringify({
    type: "tool_finished",
    round: 2,
    call_id: "c2",
    name: "read_file",
    status: "ok",
    result: "中".repeat(2000),
  }));
  assert.ok(Buffer.byteLength(multibyte.result) <= 4096);
  assert.equal(multibyte.result, "中".repeat(1365));
  assert.equal(eventForAgentOutput(JSON.stringify({
    type: "tool_finished",
    round: 1,
    call_id: "c3",
    name: "read_file",
    status: "ok",
    result: 42,
  })), null);
});

test("reports whether older conversation history was truncated", () => {
  assert.deepEqual(metaForConversation([{ role: "user", text: "hi" }]), {
    type: "meta", history_truncated: false,
  });
  const long = Array.from({ length: 42 }, (_, index) => ({ role: index % 2 ? "assistant" : "user", text: "m" + index }));
  assert.deepEqual(metaForConversation(long), { type: "meta", history_truncated: true });
});

test("restores CRLF line endings on save", () => {
  assert.equal(normalizeLineEndings("a\nb\n", "lf"), "a\nb\n");
  assert.equal(normalizeLineEndings("a\r\nb\r\n", "lf"), "a\nb\n");
  assert.equal(normalizeLineEndings("a\nb\n", "crlf"), "a\r\nb\r\n");
});

test("workspace file API preserves CRLF files end to end", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-crlf-"));
  await writeFile(join(workspaceRoot, "crlf.mbt"), "fn main {\r\n  println(1)\r\n}\r\n", "utf8");
  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const api = "http://127.0.0.1:" + port + "/api/workspace";
  try {
    const opened = await (await fetch(api + "/file?path=crlf.mbt")).json();
    assert.equal(opened.line_endings, "crlf");
    assert.match(opened.content, /\r\n/);

    const saved = await fetch(api + "/file", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: "crlf.mbt", content: "fn main {\n  println(2)\n}\n", line_endings: "crlf" }),
    });
    assert.equal(saved.status, 200);
    assert.equal(await readFile(join(workspaceRoot, "crlf.mbt"), "utf8"), "fn main {\r\n  println(2)\r\n}\r\n");
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("workspace file API rejects non-UTF-8 files", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-utf8-"));
  await writeFile(join(workspaceRoot, "latin.mbt"), Buffer.from([0x66, 0x6e, 0xff, 0xfe, 0x0a]));
  const server = serve({ listenPort: 0, workspaceRoot });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const api = "http://127.0.0.1:" + port + "/api/workspace";
  try {
    const response = await fetch(api + "/file?path=latin.mbt");
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.match(body.error, /UTF-8/);
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("registers workspaces and persists task lifecycle events", async () => {
  const workspaceRoot = await mkdtemp(join(tmpdir(), "moonsage-registered-workspace-"));
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-task-store-"));
  await writeFile(join(workspaceRoot, "README.md"), "# task\n", "utf8");
  let receivedContext;
  const server = serve({
    listenPort: 0,
    workspaceRoot,
    workspaceDataDirectory: dataRoot,
    agentRunner: async (_messages, emit, _signal, context) => {
      receivedContext = context;
      emit({ type: "final_started" });
      emit({ type: "final_delta", text: "已检查工作区" });
      return { answer: "已检查工作区" };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    const registered = await fetch(base + "/api/workspaces", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: workspaceRoot }),
    });
    assert.equal(registered.status, 201);
    const workspace = (await registered.json()).workspace;
    assert.equal(workspace.name, workspaceRoot.split(/[\\/]/).at(-1));
    assert.ok(workspace.id);

    const listed = await (await fetch(base + "/api/workspaces")).json();
    assert.equal(listed.workspaces[0].id, workspace.id);
    const defaultTaskResponse = await fetch(base + "/api/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workspace_id: workspace.id, goal: "默认任务" }),
    });
    assert.equal(defaultTaskResponse.status, 201);
    assert.equal((await defaultTaskResponse.json()).task.permission, "full-auto");
    const taskResponse = await fetch(base + "/api/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        workspace_id: workspace.id,
        goal: "检查 README",
        permission: "read-only",
      }),
    });
    assert.equal(taskResponse.status, 201);
    const task = (await taskResponse.json()).task;
    assert.equal(task.status, "queued");

    const run = await fetch(base + `/api/tasks/${task.id}/run`, { method: "POST" });
    assert.equal(run.status, 200);
    const events = (await run.text()).trim().split("\n").map(JSON.parse);
    assert.ok(events.some((event) => event.type === "started"));
    assert.ok(events.some((event) => event.type === "completed"));
    assert.deepEqual(
      events.filter((event) => event.type === "final_delta"),
      [{ type: "final_delta", text: "已检查工作区" }],
    );
    assert.equal(receivedContext.workspaceRoot, workspaceRoot);
    assert.equal(receivedContext.permission, "read-only");

    const restored = await (await fetch(base + `/api/tasks/${task.id}`)).json();
    assert.equal(restored.task.status, "completed");
    assert.ok(restored.events.some((event) => event.type === "completed"));
  } finally {
    await closeServer(server);
    await rm(workspaceRoot, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("managed tasks release leases and retain failure and cancellation snapshots", async () => {
  const repository = await createGitFixture("moonsage-managed-task-repo-");
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-managed-task-data-"));
  let cancelStartedResolve;
  const cancelStarted = new Promise((resolve) => { cancelStartedResolve = resolve; });
  let cancelObserved = false;
  const server = serve({
    listenPort: 0,
    workspaceRoot: repository,
    workspaceDataDirectory: dataRoot,
    agentRunner: async (messages, _emit, signal, context) => {
      const goal = messages.at(-1)?.text || "";
      if (goal === "success") {
        await writeFile(join(context.workspaceRoot, "success.txt"), "done\n", "utf8");
        return { answer: "done" };
      }
      if (goal === "failure") {
        await writeFile(join(context.workspaceRoot, "failure.txt"), "keep me\n", "utf8");
        return { error: "expected failure" };
      }
      await writeFile(join(context.workspaceRoot, "cancelled.txt"), "keep me too\n", "utf8");
      cancelStartedResolve();
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
      cancelObserved = true;
      // The runtime adapter historically reported aborts as errors. The task
      // lifecycle must still prioritize the AbortSignal and persist cancelled.
      return { error: "request stopped" };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  const manager = new WorktreeManager({ dataDirectory: dataRoot });
  try {
    const registered = await fetch(`${base}/api/workspaces`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: repository }),
    });
    assert.equal(registered.status, 201);
    const source = (await registered.json()).workspace;
    const createTask = async (goal) => {
      const response = await fetch(`${base}/api/tasks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspace_id: source.id,
          goal,
          permission: "controlled-write",
          workspace_mode: "managed",
          session_id: `session-${goal}`,
        }),
      });
      assert.equal(response.status, 201);
      return (await response.json()).task;
    };
    const loadTask = async (id) => (await (await fetch(`${base}/api/tasks/${id}`)).json()).task;
    const loadWorkspace = async (id) => (await manager.readRegistry()).workspaces.find((entry) => entry.id === id);

    const succeeded = await createTask("success");
    const successRun = await fetch(`${base}/api/tasks/${succeeded.id}/run`, { method: "POST" });
    assert.equal(successRun.status, 200);
    await successRun.text();
    const successTask = await loadTask(succeeded.id);
    const successWorkspace = await loadWorkspace(successTask.execution_workspace_id);
    assert.equal(successTask.status, "completed");
    assert.equal(successWorkspace.status, "ready");
    assert.equal(successWorkspace.eligible_for_cleanup, true);
    assert.equal(successWorkspace.owner_task_id, succeeded.id);
    assert.equal(await manager.activeLease(successWorkspace), null);

    const failed = await createTask("failure");
    const failureRun = await fetch(`${base}/api/tasks/${failed.id}/run`, { method: "POST" });
    assert.equal(failureRun.status, 200);
    await failureRun.text();
    const failedTask = await loadTask(failed.id);
    const failedWorkspace = await loadWorkspace(failedTask.execution_workspace_id);
    assert.equal(failedTask.status, "failed");
    assert.equal(failedWorkspace.status, "retained");
    assert.equal(failedWorkspace.eligible_for_cleanup, false);
    assert.equal(failedWorkspace.last_snapshot_id, failedTask.snapshot_id);
    assert.equal(await manager.activeLease(failedWorkspace), null);
    const failedMetadata = JSON.parse(await readFile(join(failedTask.snapshot_path, "metadata.json"), "utf8"));
    assert.equal(failedMetadata.reason, "task_failed");
    assert.equal(await readFile(join(failedTask.snapshot_path, "files", "failure.txt"), "utf8"), "keep me\n");

    const cancelled = await createTask("cancel");
    const cancelRunPromise = fetch(`${base}/api/tasks/${cancelled.id}/run`, { method: "POST" });
    await cancelStarted;
    const cancelResponse = await fetch(`${base}/api/tasks/${cancelled.id}/cancel`, { method: "POST" });
    assert.equal(cancelResponse.status, 202);
    const cancelRun = await cancelRunPromise;
    assert.equal(cancelRun.status, 200);
    await cancelRun.text();
    const cancelledTask = await loadTask(cancelled.id);
    const cancelledWorkspace = await loadWorkspace(cancelledTask.execution_workspace_id);
    assert.equal(cancelObserved, true);
    assert.equal(cancelledTask.status, "cancelled");
    assert.equal(cancelledTask.cancel_requested, true);
    assert.equal(cancelledWorkspace.status, "retained");
    assert.equal(cancelledWorkspace.eligible_for_cleanup, false);
    assert.equal(cancelledWorkspace.last_snapshot_id, cancelledTask.snapshot_id);
    assert.equal(await manager.activeLease(cancelledWorkspace), null);
    const cancelledMetadata = JSON.parse(await readFile(join(cancelledTask.snapshot_path, "metadata.json"), "utf8"));
    assert.equal(cancelledMetadata.reason, "task_cancelled");
    assert.equal(await readFile(join(cancelledTask.snapshot_path, "files", "cancelled.txt"), "utf8"), "keep me too\n");
  } finally {
    await closeServer(server);
    const registry = await manager.readRegistry().catch(() => ({ workspaces: [] }));
    for (const record of registry.workspaces) {
      if (record.kind === "worktree") await manager.removeWorktree(record, { force: true }).catch(() => {});
    }
    await rm(repository, { recursive: true, force: true });
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("aborts the agent run when the client disconnects", async () => {
  let aborted = false;
  const server = serve({
    listenPort: 0,
    agentRunner: async (_messages, _emit, signal) => {
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
      aborted = true;
      return { error: "cancelled" };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  try {
    const response = await fetch("http://127.0.0.1:" + port + "/api/agent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", text: "你好" }] }),
    });
    const reader = response.body.getReader();
    await reader.read();
    await reader.cancel();
    const deadline = Date.now() + 3000;
    while (!aborted && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    assert.equal(aborted, true);
  } finally {
    server.closeAllConnections();
    await closeServer(server);
  }
});

test("normalizes batch settings and applies canonical item events", () => {
  assert.deepEqual(normalizeBatchConfig({
    watch: true,
    interval: "2h",
    limit: 25,
    include: ["moonbitlang/*", "moonbitlang/*"],
    owner: "moonbitlang",
    keyword: ["parser"],
    exclude: "*/deprecated",
    concurrency: 4,
    max_prs: 7,
    package_timeout: "30m",
    max_calls: 120,
  }), {
    watch: true,
    interval_ms: 7_200_000,
    limit: 25,
    includes: ["moonbitlang/*"],
    owners: ["moonbitlang"],
    keywords: ["parser"],
    excludes: ["*/deprecated"],
    concurrency: 4,
    max_prs: 7,
    package_timeout_ms: 1_800_000,
    max_calls: 120,
    network_retries: 3,
    policy_hash: "mode1-v1",
  });
  assert.throws(() => normalizeBatchConfig({ concurrency: 5 }), /between 1 and 4/);
  assert.equal(eventForBatchOutput("not json"), null);
  const batch = { config: { watch: false }, status: "running", items: [] };
  applyBatchEvent(batch, {
    type: "item_enqueued",
    item: { id: "moonbitlang-parser", repository: "moonbitlang/parser", modules: ["moonbitlang/parser"] },
  });
  applyBatchEvent(batch, {
    type: "item_state",
    item_id: "moonbitlang-parser",
    state: "verified_pending_publish",
  });
  applyBatchEvent(batch, {
    type: "publish",
    item_id: "moonbitlang-parser",
    url: "https://github.com/moonbitlang/parser/pull/1",
  });
  assert.equal(batch.items[0].status, "created");
  assert.equal(batch.counts.created, 1);
});

test("batch worker uses the internal batch-audit command and forwards JSONL", async () => {
  let invocation = null;
  const events = [];
  const savedEnv = {
    GH_TOKEN: process.env.GH_TOKEN,
    GITHUB_TOKEN: process.env.GITHUB_TOKEN,
    MOONSAGE_API_KEY: process.env.MOONSAGE_API_KEY,
  };
  process.env.GH_TOKEN = "must-not-reach-worker";
  process.env.GITHUB_TOKEN = "must-not-reach-worker";
  process.env.MOONSAGE_API_KEY = "model-key-for-worker";
  let result;
  try {
    result = await runBatchWorker(
      { id: "batch-command-1234" },
      (event) => events.push(event),
      new AbortController().signal,
      {
        dataDirectory: join(tmpdir(), "moonsage-command-data"),
        workerSpawner: (executable, args, options) => {
          invocation = { executable, args, options };
          const child = new EventEmitter();
          child.pid = undefined;
          child.stdout = new PassThrough();
          child.stderr = new PassThrough();
          queueMicrotask(() => {
            child.stdout.write(JSON.stringify({
              kind: "batch_state",
              batch_id: "batch-command-1234",
              item_key: "",
              cycle: 1,
              timestamp_ms: 1,
              message: "",
              data: { status: "running" },
            }) + "\n");
            child.stdout.write(JSON.stringify({
              kind: "agent_event",
              batch_id: "batch-command-1234",
              item_key: "moonbitlang--demo",
              cycle: 1,
              timestamp_ms: 2,
              message: "调用工具 read_file",
              data: { type: "tool_started", tool: "read_file" },
            }) + "\n");
            child.stdout.end();
            child.emit("close", 0, null);
          });
          return child;
        },
      },
    );
  } finally {
    for (const [name, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
  assert.deepEqual(invocation.args.slice(-5), [
    "batch-audit", "--worker", "--batch-id", "batch-command-1234", "--stream-json",
  ]);
  assert.equal(invocation.options.env.MOONSAGE_DATA_DIR, join(tmpdir(), "moonsage-command-data"));
  assert.equal(invocation.options.env.MOONSAGE_API_KEY, "model-key-for-worker");
  assert.equal(invocation.options.env.GH_TOKEN, undefined);
  assert.equal(invocation.options.env.GITHUB_TOKEN, undefined);
  assert.equal(result.code, 0);
  assert.equal(events[0].kind, "batch_state");
  assert.equal(events.some((event) => event.kind === "agent_event"), true);
  assert.equal(events.find((event) => event.kind === "agent_event").data.tool, "read_file");
});

test("batch API persists worker events, serves SSE, and redacts secrets", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-store-"));
  const seen = [];
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, _signal, context) => {
      seen.push({ id: batch.id, dataDirectory: context.dataDirectory });
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_created" });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "snapshot_fetched",
        cycle: 1,
        items: [{ id: "moonbitlang-json", repository: "moonbitlang/json", modules: ["moonbitlang/json"] }],
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "item_state", item_id: "moonbitlang-json", state: "verifying", attempts: 1,
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "validation", item_id: "moonbitlang-json", result: { check: true, build: true, test: true },
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "log", message: "Authorization: Bearer [redacted]",
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "publish",
        item_id: "moonbitlang-json",
        status: "created",
        pr_url: "https://github.com/moonbitlang/json/pull/7",
      });
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "completed" });
      return { code: 0 };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    const rejected = await fetch(base + "/api/batches", { method: "POST", body: "{}" });
    assert.equal(rejected.status, 415);
    const createdResponse = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ limit: 3, concurrency: 2, include: ["moonbitlang/*"] }),
    });
    assert.equal(createdResponse.status, 201);
    const created = (await createdResponse.json()).batch;
    assert.equal(created.status, "queued");
    assert.equal(created.config.limit, 3);

    const run = await fetch(`${base}/api/batches/${created.id}/run`, { method: "POST" });
    assert.equal(run.status, 202);
    const completed = await waitForBatch(base, created.id, (batch) => batch.status === "completed");
    assert.equal(completed.items[0].status, "created");
    assert.equal(completed.items[0].validation.check, true);
    assert.equal(completed.items[0].pr_url, "https://github.com/moonbitlang/json/pull/7");
    assert.deepEqual(seen, [{ id: created.id, dataDirectory: dataRoot }]);

    const listed = await (await fetch(base + "/api/batches")).json();
    assert.equal(listed.batches[0].id, created.id);
    const persisted = await readFile(join(dataRoot, "batches", `${created.id}.json`), "utf8");
    const record = JSON.parse(persisted);
    assert.equal(record.schema_version, 1);
    assert.deepEqual(record.config.includes, ["moonbitlang/*"]);
    assert.equal(record.config.policy_hash, "mode1-v1");
    assert.doesNotMatch(persisted, /ghp-abcdefghijklmnop/);
    const eventLog = await readFile(join(dataRoot, "batches", `${created.id}.jsonl`), "utf8");
    assert.match(eventLog, /\[redacted\]/);
    assert.match(eventLog, /"kind":"batch_created"/);
    assert.match(eventLog, /"kind":"publish"/);
    assert.equal(eventLog.match(/"kind":"publish"/g)?.length, 1);
    assert.equal(eventLog.trim().split(/\r?\n/).length, 7, "server must not duplicate worker-owned events");

    const stream = await fetch(`${base}/api/batches/${created.id}/events`);
    assert.equal(stream.status, 200);
    assert.match(stream.headers.get("content-type"), /^text\/event-stream/);
    const reader = stream.body.getReader();
    const first = new TextDecoder().decode((await reader.read()).value);
    assert.match(first, /data: \{"kind":"batch_created"/);
    await reader.cancel();
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch controls pause, resume, and cancel an injected worker", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-control-"));
  let workerStarted = false;
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, signal, context) => {
      workerStarted = true;
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "running" });
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
      return { aborted: true };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    const response = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const batch = (await response.json()).batch;
    await fetch(`${base}/api/batches/${batch.id}/run`, { method: "POST" });
    assert.equal(workerStarted, true);
    await waitForBatch(base, batch.id, (current) => current.status === "running");
    const paused = await fetch(`${base}/api/batches/${batch.id}/pause`, { method: "POST" });
    assert.equal(paused.status, 200);
    assert.equal((await paused.json()).batch.status, "running");
    assert.equal(JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.control.json`), "utf8")).pause, true);
    assert.equal(JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.json`), "utf8")).status, "running");

    const resumed = await fetch(`${base}/api/batches/${batch.id}/resume`, { method: "POST" });
    assert.equal(resumed.status, 200);
    assert.equal((await resumed.json()).batch.status, "running");
    assert.equal(JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.control.json`), "utf8")).pause, false);
    const cancelled = await fetch(`${base}/api/batches/${batch.id}/cancel`, { method: "POST" });
    assert.equal(cancelled.status, 200);
    assert.equal((await cancelled.json()).batch.status, "running");
    assert.equal(JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.control.json`), "utf8")).cancel, true);
    assert.equal(JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.json`), "utf8")).status, "running");
    // Once the injected worker exits, the server settles the record from the
    // durable control file so the batch cannot remain "running" forever.
    await waitForBatch(base, batch.id, (current) => current.status === "cancelled");
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.json`), "utf8")).status,
      "cancelled",
    );
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("cancelling a queued batch without a running worker persists cancelled", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-queued-cancel-"));
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async () => ({ code: 0 }),
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const batch = (await created.json()).batch;
    assert.equal(batch.status, "queued");
    const cancelled = await fetch(`${base}/api/batches/${batch.id}/cancel`, { method: "POST" });
    assert.equal(cancelled.status, 200);
    const body = (await cancelled.json()).batch;
    assert.equal(body.status, "cancelled");
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.json`), "utf8")).status,
      "cancelled",
    );
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.control.json`), "utf8")).cancel,
      true,
    );
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("pausing a queued batch without a running worker persists paused", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-queued-pause-"));
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async () => ({ code: 0 }),
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const batch = (await created.json()).batch;
    assert.equal(batch.status, "queued");
    const paused = await fetch(`${base}/api/batches/${batch.id}/pause`, { method: "POST" });
    assert.equal(paused.status, 200);
    const body = (await paused.json()).batch;
    assert.equal(body.status, "paused");
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.json`), "utf8")).status,
      "paused",
    );
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${batch.id}.control.json`), "utf8")).pause,
      true,
    );
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch retry and approval leave worker-owned record states untouched", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-control-contract-"));
  let workerRuns = 0;
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async () => {
      workerRuns += 1;
      return { code: 0 };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const id = (await created.json()).batch.id;
    const recordPath = join(dataRoot, "batches", `${id}.json`);
    const record = JSON.parse(await readFile(recordPath, "utf8"));
    record.status = "completed";
    record.items = [
      {
        key: "retry-contract",
        repository: "moonbitlang/retry-contract",
        module_names: ["moonbitlang/retry-contract"],
        status: "failed",
        attempts: 1,
        error: "network",
        validation: {},
      },
      {
        key: "approve-contract",
        repository: "moonbitlang/approve-contract",
        module_names: ["moonbitlang/approve-contract"],
        status: "verified_pending_publish",
        attempts: 1,
        error: "",
        prepared_commit: "local-draft-commit",
        validation: {},
      },
    ];
    const persistedBefore = JSON.stringify(record, null, 2) + "\n";
    await writeFile(recordPath, persistedBefore, "utf8");

    const retried = await fetch(`${base}/api/batches/${id}/items/retry-contract/retry`, { method: "POST" });
    assert.equal(retried.status, 202);
    const retryBody = (await retried.json()).batch;
    assert.equal(retryBody.status, "completed");
    assert.equal(retryBody.items.find((item) => item.key === "retry-contract").status, "failed");
    assert.equal(await readFile(recordPath, "utf8"), persistedBefore);
    assert.deepEqual(
      JSON.parse(await readFile(join(dataRoot, "batches", `${id}.control.json`), "utf8")).retry_items,
      ["retry-contract"],
    );

    const deadline = Date.now() + 1000;
    while (workerRuns < 1 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
    const approved = await fetch(`${base}/api/batches/${id}/items/approve-contract/approve`, { method: "POST" });
    assert.equal(approved.status, 202);
    const approveBody = (await approved.json()).batch;
    assert.equal(approveBody.status, "completed");
    assert.equal(
      approveBody.items.find((item) => item.key === "approve-contract").status,
      "verified_pending_publish",
    );
    assert.equal(await readFile(recordPath, "utf8"), persistedBefore);
    const control = JSON.parse(await readFile(join(dataRoot, "batches", `${id}.control.json`), "utf8"));
    assert.deepEqual(control.retry_items, ["retry-contract"]);
    assert.deepEqual(control.approved_items, ["approve-contract"]);
    assert.equal(workerRuns, 2);
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch item retry and approval restart terminal work without duplicating items", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-items-"));
  let runCount = 0;
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, _signal, context) => {
      runCount += 1;
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "running" });
      if (runCount === 1) {
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_enqueued",
          item: { id: "retry-item", repository: "moonbitlang/retry", status: "failed" },
        });
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_state", item_id: "retry-item", state: "failed", message: "network",
        });
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_enqueued",
          item: { id: "approval-item", repository: "moonbitlang/approval", status: "verified_pending_publish" },
        });
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_state", item_id: "approval-item", state: "verified_pending_publish",
        });
        await persistFakeBatchEvent(batch, context, emit, {
          type: "prepared",
          item_id: "approval-item",
          prepared_branch: "moonsage/mode1/approval",
          prepared_commit: "local-approval-commit",
        });
      } else if (runCount === 2) {
        const control = JSON.parse(await readFile(context.paths.control, "utf8"));
        assert.deepEqual(control.retry_items, ["retry-item"]);
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_state", item_id: "retry-item", state: "no_changes", attempts: 1,
        });
      } else {
        const control = JSON.parse(await readFile(context.paths.control, "utf8"));
        assert.deepEqual(control.approved_items, ["approval-item"]);
        await persistFakeBatchEvent(batch, context, emit, {
          type: "publish",
          item_id: "approval-item",
          status: "created",
          pr_url: "https://github.com/moonbitlang/approval/pull/2",
        });
      }
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "completed" });
      return { code: 0 };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const id = (await created.json()).batch.id;
    await fetch(`${base}/api/batches/${id}/run`, { method: "POST" });
    await waitForBatch(base, id, (batch) => batch.status === "completed" && batch.items.length === 2);

    const retried = await fetch(`${base}/api/batches/${id}/items/retry-item/retry`, { method: "POST" });
    assert.equal(retried.status, 202);
    const afterRetry = await waitForBatch(base, id, (batch) => (
      batch.status === "completed" && batch.items.find((item) => item.id === "retry-item")?.status === "no_changes"
    ));
    assert.equal(afterRetry.items.find((item) => item.id === "retry-item").attempts, 1);

    const approved = await fetch(`${base}/api/batches/${id}/items/approval-item/approve`, { method: "POST" });
    assert.equal(approved.status, 202);
    const afterApproval = await waitForBatch(base, id, (batch) => (
      batch.status === "completed" && batch.items.find((item) => item.id === "approval-item")?.status === "created"
    ));
    assert.equal(afterApproval.items.length, 2);
    assert.equal(runCount, 3);
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch prepare drafts locally before a manual submit", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-prepare-"));
  let runCount = 0;
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, _signal, context) => {
      runCount += 1;
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "running" });
      if (runCount === 1) {
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_enqueued",
          item: { id: "draft-item", repository: "moonbitlang/draft", status: "verified_pending_publish" },
        });
        await persistFakeBatchEvent(batch, context, emit, {
          type: "item_state", item_id: "draft-item", state: "verified_pending_publish",
        });
      } else if (runCount === 2) {
        const control = JSON.parse(await readFile(context.paths.control, "utf8"));
        assert.deepEqual(control.prepare_items, ["draft-item"]);
        await persistFakeBatchEvent(batch, context, emit, {
          type: "prepared",
          item_id: "draft-item",
          prepared_branch: "moonsage/mode1/draft",
          prepared_commit: "local-draft-commit",
        });
      } else {
        const control = JSON.parse(await readFile(context.paths.control, "utf8"));
        assert.deepEqual(control.approved_items, ["draft-item"]);
        await persistFakeBatchEvent(batch, context, emit, {
          type: "publish",
          item_id: "draft-item",
          status: "created",
          pr_url: "https://github.com/moonbitlang/draft/pull/3",
        });
      }
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "completed" });
      return { code: 0 };
    },
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const id = (await created.json()).batch.id;
    await fetch(`${base}/api/batches/${id}/run`, { method: "POST" });
    await waitForBatch(base, id, (batch) => (
      batch.status === "completed" && batch.items.find((item) => item.id === "draft-item")
    ));

    // 未拟稿时确认提交必须被拒绝。
    const premature = await fetch(`${base}/api/batches/${id}/items/draft-item/approve`, { method: "POST" });
    assert.equal(premature.status, 409);

    const prepared = await fetch(`${base}/api/batches/${id}/items/draft-item/prepare`, { method: "POST" });
    assert.equal(prepared.status, 202);
    await waitForBatch(base, id, (batch) => (
      batch.items.find((item) => item.id === "draft-item")?.prepared_commit === "local-draft-commit"
    ));
    assert.deepEqual(
      JSON.parse(await readFile(join(dataRoot, "batches", `${id}.control.json`), "utf8")).prepare_items,
      ["draft-item"],
    );

    // 已拟稿后再次 prepare 被拒绝。
    const reprepared = await fetch(`${base}/api/batches/${id}/items/draft-item/prepare`, { method: "POST" });
    assert.equal(reprepared.status, 409);

    const submitted = await fetch(`${base}/api/batches/${id}/items/draft-item/approve`, { method: "POST" });
    assert.equal(submitted.status, 202);
    await waitForBatch(base, id, (batch) => (
      batch.items.find((item) => item.id === "draft-item")?.status === "created"
    ));
    const finalBatch = await (await fetch(`${base}/api/batches/${id}`)).json();
    assert.equal(finalBatch.batch.items.find((item) => item.id === "draft-item").pr_url, "https://github.com/moonbitlang/draft/pull/3");
    assert.equal(runCount, 3);
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch review releases a needs-review item without publishing", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-review-"));
  const server = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async () => ({ code: 0 }),
  });
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const created = await fetch(base + "/api/batches", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const id = (await created.json()).batch.id;
    const recordPath = join(dataRoot, "batches", `${id}.json`);
    const record = JSON.parse(await readFile(recordPath, "utf8"));
    record.status = "completed";
    record.items = [
      {
        key: "review-item",
        repository: "moonbitlang/review",
        module_names: ["moonbitlang/review"],
        status: "verified_pending_publish",
        needs_review: true,
        attempts: 1,
        validation: { check_passed: true, build_passed: true, test_passed: true },
      },
      {
        key: "plain-item",
        repository: "moonbitlang/plain",
        module_names: ["moonbitlang/plain"],
        status: "verified_pending_publish",
        needs_review: false,
        attempts: 1,
        validation: { check_passed: true, build_passed: true, test_passed: true },
      },
    ];
    await writeFile(recordPath, JSON.stringify(record, null, 2) + "\n", "utf8");

    // 非 needs_review 的 item 不能走 review。
    const rejected = await fetch(`${base}/api/batches/${id}/items/plain-item/review`, { method: "POST" });
    assert.equal(rejected.status, 409);

    const released = await fetch(`${base}/api/batches/${id}/items/review-item/review`, { method: "POST" });
    assert.equal(released.status, 202);
    const persisted = JSON.parse(await readFile(recordPath, "utf8"));
    assert.equal(persisted.items.find((item) => item.key === "review-item").needs_review, false);
    assert.equal(persisted.items.find((item) => item.key === "review-item").status, "verified_pending_publish");

    // 放行后再次 review 被拒绝。
    const again = await fetch(`${base}/api/batches/${id}/items/review-item/review`, { method: "POST" });
    assert.equal(again.status, 409);
  } finally {
    await closeServer(server);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch recovery requeues in-progress items and restarts the worker", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-recovery-"));
  const first = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, signal, context) => {
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "running" });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "item_enqueued",
        item: { id: "moonbitlang-recover", repository: "moonbitlang/recover", status: "auditing" },
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "item_state", item_id: "moonbitlang-recover", state: "auditing",
      });
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
      return { aborted: true };
    },
  });
  await new Promise((resolve) => first.once("listening", resolve));
  const firstBase = `http://127.0.0.1:${first.address().port}`;
  const created = await fetch(firstBase + "/api/batches", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  const id = (await created.json()).batch.id;
  await fetch(`${firstBase}/api/batches/${id}/run`, { method: "POST" });
  await waitForBatch(firstBase, id, (batch) => batch.items[0]?.status === "auditing");
  await closeServer(first);
  await writeFile(join(dataRoot, "batches", `${id}.lock`), "interrupted-worker\n", "utf8");

  let recoveredStatus = "";
  const second = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, _signal, context) => {
      recoveredStatus = batch.items[0]?.status || "";
      // The real MoonBit worker calls recover_batch before executing queued work.
      batch.items[0].status = "queued";
      await persistFakeBatchEvent(batch, context, emit, {
        type: "batch_state", state: "running", recovered: true,
      });
      await persistFakeBatchEvent(batch, context, emit, {
        type: "item_state", item_id: "moonbitlang-recover", state: "no_changes",
      });
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "completed" });
      return { code: 0 };
    },
  });
  await new Promise((resolve) => second.once("listening", resolve));
  const secondBase = `http://127.0.0.1:${second.address().port}`;
  try {
    const completed = await waitForBatch(secondBase, id, (batch) => batch.status === "completed");
    assert.equal(recoveredStatus, "auditing");
    assert.equal(completed.items[0].status, "no_changes");
    await assert.rejects(readFile(join(dataRoot, "batches", `${id}.lock`), "utf8"), /ENOENT/);
    const events = await readFile(join(dataRoot, "batches", `${id}.jsonl`), "utf8");
    assert.match(events, /"recovered":true/);
  } finally {
    await closeServer(second);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("batch recovery preserves a pending cancel control file", async () => {
  const dataRoot = await mkdtemp(join(tmpdir(), "moonsage-batch-recovery-cancel-"));
  const seed = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async () => ({ code: 0 }),
  });
  await new Promise((resolve) => seed.once("listening", resolve));
  const seedBase = `http://127.0.0.1:${seed.address().port}`;
  const created = await fetch(seedBase + "/api/batches", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  const id = (await created.json()).batch.id;
  const recordPath = join(dataRoot, "batches", `${id}.json`);
  const record = JSON.parse(await readFile(recordPath, "utf8"));
  record.status = "running";
  await writeFile(recordPath, JSON.stringify(record, null, 2) + "\n", "utf8");
  await writeFile(
    join(dataRoot, "batches", `${id}.control.json`),
    JSON.stringify({
      pause: false,
      cancel: true,
      retry_items: [],
      approved_items: [],
      prepare_items: [],
      updated_at_ms: Date.now(),
    }, null, 2) + "\n",
    "utf8",
  );
  await writeFile(join(dataRoot, "batches", `${id}.lock`), "interrupted-worker\n", "utf8");
  await closeServer(seed);

  let observedCancel = null;
  let workerRan = false;
  const recovered = serve({
    listenPort: 0,
    workspaceDataDirectory: dataRoot,
    batchWorker: async (batch, emit, _signal, context) => {
      workerRan = true;
      observedCancel = JSON.parse(await readFile(context.paths.control, "utf8")).cancel;
      await persistFakeBatchEvent(batch, context, emit, { type: "batch_state", state: "running" });
      return { code: 0 };
    },
  });
  await new Promise((resolve) => recovered.once("listening", resolve));
  try {
    const deadline = Date.now() + 3000;
    while (!workerRan && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(workerRan, true);
    assert.equal(observedCancel, true);
    assert.equal(
      JSON.parse(await readFile(join(dataRoot, "batches", `${id}.control.json`), "utf8")).cancel,
      true,
    );
  } finally {
    await closeServer(recovered);
    await rm(dataRoot, { recursive: true, force: true });
  }
});

test("killProcessTree terminates the child process", { skip: !canSpawnChildren || process.platform !== "win32" }, async () => {
  const child = spawn("cmd.exe", ["/c", "ping", "-n", "60", "127.0.0.1"], { windowsHide: true, stdio: "ignore" });
  await new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  killProcessTree(child);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("child process did not exit")), 5000);
    child.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
  });
});
