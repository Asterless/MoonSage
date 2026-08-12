import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { buildAgentPrompt, parseAgentEvents, resolveRequestPath, serve } from "./dev_server.mjs";

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
    assert.deepEqual(await response.json(), { answer: "来自 Agent 的回答" });
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
