import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";

import { buildAgentPrompt, eventForAgentOutput, isTrustedRequest, killProcessTree, metaForConversation, normalizeLineEndings, parseAgentEvents, parseGitStatus, requireJsonContentType, resolveRequestPath, resolveWorkspacePath, serve } from "./dev_server.mjs";

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
