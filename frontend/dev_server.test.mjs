import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";

import { buildAgentPrompt, eventForAgentOutput, parseAgentEvents, parseGitStatus, resolveRequestPath, resolveWorkspacePath, serve } from "./dev_server.mjs";

const execFileAsync = promisify(execFile);

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
  assert.equal(resolveWorkspacePath(workspace, ".git/config"), null);
  assert.equal(resolveWorkspacePath(workspace, ".moonsage/sessions/private.json"), null);
  if (process.platform === "win32") {
    assert.equal(resolveWorkspacePath(workspace, "C:/Windows/System32/config"), null);
  }
});

test("parses staged, unstaged, and untracked git status", () => {
  assert.deepEqual(parseGitStatus("M  staged.mbt\0 M working.mbt\0?? new.mbt\0"), [
    { path: "staged.mbt", index: "M", worktree: " ", staged: true, unstaged: false, untracked: false },
    { path: "working.mbt", index: " ", worktree: "M", staged: false, unstaged: true, untracked: false },
    { path: "new.mbt", index: "?", worktree: "?", staged: false, unstaged: true, untracked: true },
  ]);
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

test("maps agent lifecycle output to browser stream events", () => {
  assert.deepEqual(eventForAgentOutput('{"type":"thinking_delta","text":"private"}'), {
    type: "status",
    message: "正在分析问题",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"tool_started","name":"search"}'), {
    type: "status",
    message: "正在使用 search",
  });
  assert.deepEqual(eventForAgentOutput('{"type":"final_delta","text":"答案"}'), {
    type: "delta",
    text: "答案",
  });
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
      { type: "status", message: "正在启动 Agent" },
      { type: "delta", text: "来自 Agent 的回答" },
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
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("streams answer deltas before the agent process finishes", async () => {
  let finishAgent;
  const server = serve({
    listenPort: 0,
    agentRunner: async (_messages, emit) => {
      emit({ type: "status", message: "正在组织回答" });
      emit({ type: "delta", text: "第一段" });
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
    assert.match(firstChunk, /"type":"delta","text":"第一段"/);
    finishAgent();
    await reader.cancel();
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("workspace API edits files and completes a git workflow", async () => {
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
    await rm(join(workspaceRoot, ".env"));
    await rm(join(workspaceRoot, ".moonsage"), { recursive: true });

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
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("workspace API unstages files before the first commit", async () => {
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
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await rm(workspaceRoot, { recursive: true, force: true });
  }
});
