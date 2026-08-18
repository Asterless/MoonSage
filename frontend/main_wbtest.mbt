///|
fn test_request(id : Int, session_id : String, prompt : String) -> Request {
  {
    id,
    session_id,
    prompt,
    status: "运行中",
    answer_buf: [],
    answer_shown: "",
    thinking_buf: [],
    thinking_shown: "",
    flush_pending: false,
    tools: [],
    warning: "",
    history_truncated: false,
  }
}

///|
fn test_model(
  sessions : Array[Session],
  active : Int,
  request : RequestState,
) -> Model {
  {
    draft: "",
    sessions,
    active_session: active,
    request,
    command_open: false,
    sidebar_open: true,
    theme: "light",
    compact: false,
    workspace_overlay: false,
    workspace: initial_workspace(),
    batch: initial_batch(),
    next_id: 100,
    pending_new_session: false,
  }
}

///|
test "theme values normalize and toggle" {
  assert_eq(normalize_theme(""), "light")
  assert_eq(normalize_theme("system"), "light")
  assert_eq(normalize_theme("dark"), "dark")
  assert_eq(opposite_theme("light"), "dark")
  assert_eq(opposite_theme("dark"), "light")
}

///|
test "workspace binding restores a valid session id before stored index" {
  let sessions : Array[Session] = [
    { id: "first", title: "First", detail: "", messages: [] },
    { id: "bound", title: "Bound", detail: "", messages: [] },
  ]
  assert_eq(resolved_active_session_index(sessions, 0, "bound"), 1)
  assert_eq(resolved_active_session_index(sessions, 1, "missing"), 1)
  assert_eq(resolved_active_session_index(sessions, 99, "missing"), 0)
  assert_eq(
    decode_workspace_binding(
      "{\"active_workspace_id\":\"legacy-workspace\",\"active_session_id\":\"legacy-session\"}",
    ),
    ("legacy-workspace", "legacy-session"),
  )
}

///|
test "viewport changes only flip layout at the compact boundary" {
  let desktop = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Idle,
  )
  let compact = with_viewport_width(desktop, 760)
  assert_true(compact.compact)
  assert_true(compact.workspace_overlay)
  assert_false(compact.sidebar_open)
  let still_compact = with_viewport_width(
    { ..compact, sidebar_open: true },
    600,
  )
  assert_true(still_compact.sidebar_open)
  let back_desktop = with_viewport_width(still_compact, 761)
  assert_false(back_desktop.compact)
  assert_true(back_desktop.workspace_overlay)
  assert_true(back_desktop.sidebar_open)
  let wide_workspace = with_viewport_width(back_desktop, 1041)
  assert_false(wide_workspace.workspace_overlay)
  assert_true(wide_workspace.sidebar_open)
}

///|
test "workspace files group by top-level directory and filter by full path" {
  let groups = workspace_file_groups(
    ["README.md", "src/main.mbt", "src/lib/util.mbt", "tests/main.mbt"],
    "",
  )
  assert_eq(groups.length(), 3)
  assert_eq(groups[0].label, "根目录")
  assert_eq(groups[0].files[0].relative_path, "README.md")
  assert_eq(groups[1].label, "src")
  assert_eq(groups[1].files[1].relative_path, "lib/util.mbt")
  let filtered = workspace_file_groups(
    ["README.md", "src/main.mbt", "src/lib/util.mbt", "tests/main.mbt"],
    "util",
  )
  assert_eq(filtered.length(), 1)
  assert_eq(filtered[0].label, "src")
  assert_eq(filtered[0].files[0].path, "src/lib/util.mbt")
}

///|
#warnings("-alert_unstable")
test "semantic views expose navigation and workspace states" {
  let model = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Idle,
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let session_html = @rabbita.render_to_string(fn() {
    Val::constant(session_view(model, emit))
  })
  assert_true(session_html.contains("<aside"))
  assert_true(session_html.contains("aria-label=\"会话列表\""))
  assert_true(session_html.contains("aria-current=\"page\""))
  assert_true(session_html.contains("aria-pressed=\"false\""))
  let workspace = {
    ..initial_workspace(),
    open: true,
    files: ["README.md", "src/main.mbt"],
    selected_path: "src/main.mbt",
  }
  let workspace_html = @rabbita.render_to_string(fn() {
    Val::constant(workspace_view(workspace, false, false, emit))
  })
  assert_true(workspace_html.contains("role=\"tab\""))
  assert_true(workspace_html.contains("aria-selected=\"true\""))
  assert_true(workspace_html.contains("aria-expanded=\"true\""))
  assert_true(workspace_html.contains("aria-current=\"location\""))
  assert_true(workspace_html.contains("根目录"))
  assert_true(workspace_html.contains("src"))
  assert_true(workspace_html.contains("Local · ready"))
  assert_false(workspace_html.contains("{workspace.status}"))
  let modal_html = @rabbita.render_to_string(fn() {
    Val::constant(workspace_view(workspace, true, false, emit))
  })
  assert_true(modal_html.contains("role=\"dialog\""))
  assert_true(modal_html.contains("aria-modal=\"true\""))
}

///|
test "async replies stay with their originating session" {
  let model : Model = test_model(
    [
      { id: "origin", title: "Origin", detail: "", messages: [] },
      { id: "active", title: "Active", detail: "", messages: [] },
    ],
    1,
    Idle,
  )
  let updated = append_session_message(model, "origin", {
    role: "assistant",
    text: "origin reply",
  })
  assert_eq(updated.active_session, 1)
  let origin_messages = updated.sessions[0].messages
  assert_eq(origin_messages[origin_messages.length() - 1].text, "origin reply")
  assert_true(
    !updated.sessions[1].messages.any(fn(message) {
      message.text == "origin reply"
    }),
  )
}

///|
test "stream events only update their originating request" {
  let request = test_request(7, "origin", "question")
  let model : Model = test_model(
    [
      { id: "origin", title: "Origin", detail: "", messages: [] },
      { id: "active", title: "Active", detail: "", messages: [] },
    ],
    1,
    Sending(request),
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (streamed, _) = update(model, AgentDelta(7, " second"), emit)
  guard streamed.request is Sending(after) else { fail("expected sending") }
  assert_eq(after.answer_buf, [" second"])
  assert_eq(after.answer_shown, "")
  let (unchanged, _) = update(streamed, AgentDelta(99, "wrong"), emit)
  assert_true(unchanged == streamed)
  let (failed, _) = update(streamed, AgentFailed(99, "stale failure"), emit)
  assert_true(failed == streamed)
}

///|
test "AgentFlush commits buffered deltas once" {
  let request = {
    ..test_request(3, "s", "p"),
    flush_pending: true,
    answer_buf: ["a", "b"],
  }
  let model : Model = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Sending(request),
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (flushed, _) = update(model, AgentFlush(3), emit)
  guard flushed.request is Sending(after) else { fail("expected sending") }
  assert_eq(after.answer_shown, "ab")
  assert_eq(after.answer_buf, [])
  assert_false(after.flush_pending)
}

///|
test "tool calls start running and finish with their result" {
  let model : Model = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Sending(test_request(1, "s", "p")),
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (started, _) = update(
    model,
    AgentToolStarted(1, "c1", "search_modules", "{\"query\":\"http\"}", 2),
    emit,
  )
  guard started.request is Sending(with_tool) else { fail("expected sending") }
  assert_eq(with_tool.tools.length(), 1)
  assert_eq(with_tool.tools[0].status, "running")
  let (done, _) = update(started, AgentToolFinished(1, "c1", "ok", "[]"), emit)
  guard done.request is Sending(finished_tools) else {
    fail("expected sending")
  }
  assert_eq(finished_tools.tools[0].status, "ok")
  assert_eq(finished_tools.tools[0].result, "[]")
}

///|
test "Agent responses prefer canonical protocol events" {
  assert_eq(
    decode_agent_event(
      "{\"type\":\"started\",\"permission\":\"controlled-write\"}",
    ),
    Started("controlled-write"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"final_delta\",\"text\":\"真实回答\"}"),
    Delta("真实回答"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"final_started\"}"),
    Status("正在组织回答"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"status\",\"message\":\"正在搜索\"}"),
    Status("正在搜索"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"error\",\"message\":\"missing key\"}"),
    StreamError("missing key"),
  )
  assert_eq(
    decode_agent_event(
      "{\"type\":\"tool_started\",\"call_id\":\"c1\",\"name\":\"search_modules\",\"arguments\":\"{}\",\"round\":1}",
    ),
    ToolStarted("c1", "search_modules", "{}", 1),
  )
  assert_eq(
    decode_agent_event(
      "{\"type\":\"tool_finished\",\"call_id\":\"c1\",\"name\":\"search_modules\",\"status\":\"ok\",\"result\":\"[]\",\"round\":1}",
    ),
    ToolFinished("c1", "ok", "[]", 1),
  )
  assert_eq(
    decode_agent_event(
      "{\"type\":\"retrying\",\"attempt\":2,\"reason\":\"429\"}",
    ),
    Retry(2, "429"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"warning\",\"message\":\"budget\"}"),
    Warning("budget"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"thinking_delta\",\"text\":\"考虑中\"}"),
    Thinking("考虑中"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"meta\",\"history_truncated\":true}"),
    Meta(true),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"paused\",\"reason\":\"等待批准\"}"),
    Paused("等待批准"),
  )
  assert_eq(decode_agent_event("{\"type\":\"completed\"}"), Completed)
  assert_eq(
    decode_agent_event("{\"type\":\"failed\",\"message\":\"写入被拒绝\"}"),
    StreamError("写入被拒绝"),
  )
  assert_true(decode_agent_event("not json") is Ignored)
}

///|
test "agent workspace requests carry session and execution mode" {
  guard agent_request_body(
      "session-7",
      [{ role: "user", text: "inspect" }],
      "workspace-12345678",
      "local",
    )
    is Object(fields) else {
    fail("expected request object")
  }
  assert_true(fields.get("session_id") is Some(String("session-7")))
  assert_true(fields.get("workspace_id") is Some(String("workspace-12345678")))
  assert_true(fields.get("workspace_mode") is Some(String("local")))
  assert_true(fields.get("permission") is Some(String("controlled-write")))
}

///|
test "Agent responses accept legacy browser aliases" {
  assert_eq(
    decode_agent_event("{\"type\":\"delta\",\"text\":\"旧回答\"}"),
    Delta("旧回答"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"thinking\",\"text\":\"旧推理\"}"),
    Thinking("旧推理"),
  )
  assert_eq(
    decode_agent_event(
      "{\"type\":\"retry\",\"attempt\":3,\"reason\":\"旧重试\"}",
    ),
    Retry(3, "旧重试"),
  )
  assert_eq(
    decode_agent_event(
      "{\"type\":\"tool_started\",\"id\":\"old-id\",\"name\":\"search_modules\",\"arguments\":\"{}\",\"round\":1}",
    ),
    ToolStarted("old-id", "search_modules", "{}", 1),
  )
}

///|
test "storage encode and decode roundtrip" {
  let sessions = [
    {
      id: "welcome",
      title: "欢迎",
      detail: "",
      messages: [{ role: "user", text: "你好" }],
    },
  ]
  let encoded = encode_storage(sessions, 0, 5)
  guard decode_storage(encoded) is Some((decoded, active, next_id)) else {
    fail("expected decode")
  }
  assert_eq(decoded, sessions)
  assert_eq(active, 0)
  assert_eq(next_id, 5)
  assert_true(decode_storage("not json") is None)
}

///|
test "session title comes from the first user prompt" {
  let model : Model = test_model(
    [{ id: "session-1", title: "新会话", detail: "", messages: [] }],
    0,
    Idle,
  )
  let titled = with_title_for_first_prompt(
    model, "帮我找一个 JSON 解析库并比较它们的性能",
  )
  assert_eq(
    titled.sessions[0].title,
    "帮我找一个 JSON 解析库并比较它们的性能",
  )
  let kept = with_title_for_first_prompt(titled, "第二个问题")
  assert_eq(
    kept.sessions[0].title,
    "帮我找一个 JSON 解析库并比较它们的性能",
  )
  let long_prompt = "这是一个非常非常长的提示词用来验证超过二十四个字符之后标题会被截断并加上省略号"
  let truncated = with_title_for_first_prompt(model, long_prompt)
  assert_eq(
    truncated.sessions[0].title,
    "这是一个非常非常长的提示词用来验证超过二十四个字…",
  )
}

///|
test "cancel commits the partial answer and returns to Idle" {
  let request = { ..test_request(4, "s", "p"), answer_shown: "第一段" }
  let model : Model = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Sending(request),
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (stopped, _) = update(model, CancelRequest, emit)
  assert_true(stopped.request is Idle)
  assert_eq(stopped.sessions[0].messages.length(), 1)
  assert_eq(stopped.sessions[0].messages[0].text, "第一段")
}

///|
test "retry starts a fresh request with a new id" {
  let request = test_request(2, "s", "p")
  let model : Model = test_model(
    [{ id: "s", title: "S", detail: "", messages: [] }],
    0,
    Failed(request, "超时"),
  )
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (retried, _) = update(model, Retry, emit)
  guard retried.request is Sending(fresh) else { fail("expected sending") }
  assert_eq(fresh.id, 100)
  assert_eq(fresh.session_id, "s")
  assert_eq(fresh.prompt, "p")
  assert_eq(retried.next_id, 101)
}

///|
#warnings("-alert_unstable")
test "Markdown renders common syntax and removes unsafe HTML" {
  let rendered = @rabbita.render_to_string(fn() {
    Val::constant(
      markdown_view(
        "## 标题\n\n**粗体**、`code` 和 [链接](https://example.com)\n\n1. 第一项\n2. 第二项\n\n```moonbit\nlet first = 1\nlet second = 2\n```\n\n<script>alert(1)</script>",
      ),
    )
  })
  assert_true(rendered.contains("<h2>标题</h2>"))
  assert_true(rendered.contains("<strong>粗体</strong>"))
  assert_true(rendered.contains("<code>code</code>"))
  assert_true(rendered.contains("<ol start=\"1\">"))
  assert_true(rendered.contains("let first = 1\nlet second = 2\n"))
  assert_true(rendered.contains("href=\"https://example.com\""))
  assert_true(!rendered.contains("<script>"))
}

///|
#warnings("-alert_unstable")
test "Markdown recovers strong emphasis missed at text boundaries" {
  let rendered = @rabbita.render_to_string(fn() {
    Val::constant(
      markdown_view(
        "正文**重点**正文\n\n**状态：**正常\n\n** 带空格的重点 **\n\n****双层强调****\n\n\\**转义星号**\n\n`**代码保持原样**`",
      ),
    )
  })
  assert_true(rendered.contains("正文<strong>重点</strong>正文"))
  assert_true(rendered.contains("<strong>状态：</strong>正常"))
  assert_true(rendered.contains("<strong> 带空格的重点 </strong>"))
  assert_true(
    rendered.contains("<strong><strong>双层强调</strong></strong>"),
  )
  assert_true(rendered.contains("*<em>转义星号</em>"))
  assert_true(!rendered.contains("<strong>转义星号</strong>"))
  assert_true(rendered.contains("<code>**代码保持原样**</code>"))
}

///|
#warnings("-alert_unstable")
test "Markdown keeps empty star runs without hiding later emphasis" {
  let rendered = @rabbita.render_to_string(fn() {
    Val::constant(
      markdown_view(
        "****\n\n前缀****后缀\n\n**** 保留，后面 **重点**\n\n**第一** 和 **第二**\n\n结尾 **",
      ),
    )
  })
  assert_true(rendered.contains("<hr>"))
  assert_true(rendered.contains("前缀****后缀"))
  assert_true(rendered.contains("**** 保留，后面 <strong>重点</strong>"))
  assert_true(
    rendered.contains("<strong>第一</strong> 和 <strong>第二</strong>"),
  )
  assert_true(rendered.contains("结尾 **"))
}

///|
#warnings("-alert_unstable")
test "Markdown renders tables, thematic breaks, and break types" {
  let rendered = @rabbita.render_to_string(fn() {
    Val::constant(
      markdown_view(
        "| 名称 | 状态 |\n| --- | --- |\n| Markdown | 正常 |\n\n****\n\n软\n换行\n\n硬换行  \n保留",
      ),
    )
  })
  assert_true(rendered.contains("<table>"))
  assert_true(rendered.contains("<th>名称</th>"))
  assert_true(rendered.contains("<td>正常</td>"))
  assert_true(rendered.contains("<hr>"))
  assert_true(rendered.contains("<p>软 换行</p>"))
  assert_true(rendered.contains("硬换行<br>保留"))
}

///|
test "workspace decodes files and git status" {
  assert_eq(
    decode_workspace_registry(
      "{\"workspaces\":[{\"id\":\"workspace-1\",\"name\":\"demo\"}]}",
    ),
    Some(("workspace-1", "demo")),
  )
  let entries = decode_workspace_entries(
    "{\"workspaces\":[{\"id\":\"workspace-1\",\"name\":\"demo\",\"kind\":\"worktree\",\"managed\":true,\"lifecycle\":\"temporary\",\"status\":\"busy\",\"revision\":\"registry-rev\",\"source_id\":\"local-12345678\"}]}",
  )
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].kind, "worktree")
  assert_eq(entries[0].mode, "managed")
  assert_eq(entries[0].lifecycle, "temporary")
  assert_eq(entries[0].status, "busy")
  assert_eq(entries[0].revision, "registry-rev")
  assert_eq(entries[0].source_id, "local-12345678")
  assert_eq(
    decode_workspace_pick(
      "{\"workspace\":{\"id\":\"workspace-2\",\"name\":\"local\"}}",
    ),
    Some(("workspace-2", "local")),
  )
  assert_true(workspace_pick_cancelled("{\"cancelled\":true}"))
  assert_eq(
    decode_workspace_tree(
      "{\"root\":\"demo\",\"files\":[\"main.mbt\",\"src/lib.mbt\"]}",
    ),
    Some(("demo", ["main.mbt", "src/lib.mbt"])),
  )
  assert_eq(
    decode_workspace_file("{\"content\":\"a\",\"line_endings\":\"crlf\"}"),
    Some(("a", "crlf")),
  )
  let workspace = {
    ..initial_workspace(),
    revision: "old-workspace-revision",
    file_revision: "file-revision",
  }
  guard apply_workspace_status(
      workspace, "{\"branch\":\"codex/workspace\",\"revision\":\"workspace-revision\",\"changes\":[{\"path\":\"main.mbt\",\"index\":\"M\",\"worktree\":\" \",\"staged\":true,\"unstaged\":false,\"untracked\":false}]}",
    )
    is Some(updated) else {
    fail("expected workspace status")
  }
  assert_eq(updated.branch, "codex/workspace")
  assert_eq(updated.revision, "workspace-revision")
  assert_eq(updated.file_revision, "file-revision")
  assert_eq(updated.changes.length(), 1)
  assert_true(updated.changes[0].staged)
}

///|
test "workspace accepts an empty registry and keeps file revisions separate" {
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let existing = {
    ..initial_workspace(),
    id: "workspace-old",
    name: "Old",
    revision: "workspace-revision",
    selected_path: "main.mbt",
  }
  guard workspace_update(
      existing,
      WorkspaceRegistryReceived("{\"workspaces\":[]}"),
      emit,
    )
    is Some((cleared, _)) else {
    fail("expected registry update")
  }
  assert_eq(cleared.id, "")
  assert_true(cleared.entries.is_empty())
  assert_eq(cleared.error, "")
  let selected = {
    ..existing,
    id: "workspace-current",
    content: "old",
    saved_content: "old",
  }
  guard workspace_update(
      selected,
      WorkspaceFileReceived(
        "workspace-current", "main.mbt", "{\"content\":\"new\",\"line_endings\":\"lf\",\"revision\":\"file-revision\"}",
      ),
      emit,
    )
    is Some((loaded, _)) else {
    fail("expected file update")
  }
  assert_eq(loaded.revision, "workspace-revision")
  assert_eq(loaded.file_revision, "file-revision")
}

///|
test "workspace protects unsaved editor state from stale saves" {
  let workspace = {
    ..initial_workspace(),
    id: "workspace-1",
    selected_path: "main.mbt",
    content: "newer",
    saved_content: "old",
    loading: true,
  }
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  guard workspace_update(
      workspace,
      WorkspaceFileSaved("workspace-1", "main.mbt", "older request"),
      emit,
    )
    is Some((updated, _)) else {
    fail("expected workspace update")
  }
  assert_eq(updated.content, "newer")
  assert_eq(updated.saved_content, "old")
  assert_true(workspace_changed(updated))
}

///|
test "workspace ignores file responses from a different workspace" {
  let workspace = {
    ..initial_workspace(),
    id: "workspace-new",
    selected_path: "README.md",
    content: "new workspace",
    saved_content: "new workspace",
  }
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  guard workspace_update(
      workspace,
      WorkspaceFileReceived(
        "workspace-old", "README.md", "{\"content\":\"old workspace\",\"line_endings\":\"lf\"}",
      ),
      emit,
    )
    is Some((updated, _)) else {
    fail("expected workspace update")
  }
  assert_true(updated == workspace)
}

///|
test "batch API records decode counters, modules, and validation evidence" {
  let source =
    #|{"batches":[{"id":"batch-1","mode":"batch-audit","status":"running","created_at":"2026-08-17T00:00:00Z","counters":{"total":4,"created":1,"no_changes":1,"failed":1,"queued":1},"items":[{"key":"moonbitlang--demo","modules":["moonbitlang/demo","moonbitlang/demo-extra"],"repository":"https://github.com/moonbitlang/demo","status":"failed","attempts":2,"validation":{"check_passed":true,"build_passed":true,"test_passed":false,"test_output":"one test failed"},"diff_summary":"2 files changed","error":"test failed"}]}]}
  guard decode_batch_list(source) is Some(batches) else {
    fail("expected batch list")
  }
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].total, 4)
  assert_eq(batches[0].completed, 3)
  assert_eq(batches[0].failed, 1)
  assert_eq(batches[0].created_prs, 1)
  guard @json.parse(source) is Object(root) else { fail("expected object") }
  guard root.get("batches") is Some(Array(values)) else {
    fail("expected values")
  }
  guard decode_batch_record(values[0]) is Some(detail) else {
    fail("expected detail")
  }
  assert_eq(detail.items.length(), 1)
  assert_eq(
    detail.items[0].module_name,
    "moonbitlang/demo, moonbitlang/demo-extra",
  )
  assert_eq(
    detail.items[0].validation,
    "check 通过 · build 通过 · test 失败",
  )
  assert_eq(detail.items[0].validation_log, "moon test\none test failed")
}

///|
test "batch mode opens independently and updates its configuration" {
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let batch = initial_batch()
  guard batch_update(batch, ToggleBatch, emit) is Some((opened, _)) else {
    fail("expected batch update")
  }
  assert_true(opened.open)
  assert_true(opened.loading)
  guard batch_update(opened, BatchConfigChanged("watch", "true"), emit)
    is Some((watching, _)) else {
    fail("expected config update")
  }
  assert_true(watching.config.watch)
  guard batch_update(watching, BatchConfigChanged("limit", "25"), emit)
    is Some((limited, _)) else {
    fail("expected limit update")
  }
  assert_eq(limited.config.limit, "25")
  assert_eq(
    batch_json_string_list("moonbitlang/*, user/pkg\nother/pkg").stringify(),
    "[\"moonbitlang/*\",\"user/pkg\",\"other/pkg\"]",
  )
}

///|
#warnings("-alert_unstable")
test "batch view exposes controls, status, item detail, and PR link" {
  let summary : BatchSummary = {
    id: "batch-1",
    status: "paused",
    mode: "batch-audit",
    total: 1,
    completed: 1,
    active: 0,
    failed: 0,
    created_prs: 0,
    created_at: "2026-08-17T00:00:00Z",
  }
  let item : BatchItem = {
    key: "moonbitlang--demo",
    module_name: "moonbitlang/demo",
    repository: "https://github.com/moonbitlang/demo",
    status: "verified_pending_publish",
    attempts: 1,
    validation: "check 通过 · build 通过 · test 通过",
    validation_log: "moon test\npassed",
    diff_summary: "1 file changed",
    pr_url: "https://github.com/moonbitlang/demo/pull/7",
    prepared_branch: "",
    prepared_commit: "",
    needs_review: false,
    error: "",
    report: "Audit report",
  }
  let batch : BatchModel = {
    ..initial_batch(),
    open: true,
    batches: [summary],
    detail: {
      summary,
      cycle: 1,
      source_revision: "abc123",
      items: [item],
      notice: "",
    },
    selected_id: "batch-1",
    selected_item: item.key,
  }
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let html = @rabbita.render_to_string(fn() {
    Val::constant(batch_view(batch, "light", emit))
  })
  assert_true(html.contains("自动审计"))
  assert_true(html.contains("aria-pressed=\"false\""))
  assert_true(html.contains("aria-current=\"page\""))
  assert_true(html.contains("aria-current=\"location\""))
  assert_true(html.contains("拟稿 PR"))
  assert_true(html.contains("验证日志"))
  assert_true(
    html.contains("href=\"https://github.com/moonbitlang/demo/pull/7\""),
  )
  let prepared_item : BatchItem = {
    ..item,
    key: "moonbitlang--prepared",
    prepared_branch: "moonsage/mode1/demo",
    prepared_commit: "local-commit-abc",
  }
  let prepared_html = @rabbita.render_to_string(fn() {
    Val::constant(
      batch_view(
        {
          ..batch,
          detail: { ..batch.detail, items: [prepared_item] },
          selected_item: prepared_item.key,
        },
        "light",
        emit,
      ),
    )
  })
  assert_true(prepared_html.contains("已拟稿待确认"))
  assert_true(prepared_html.contains("moonsage/mode1/demo"))
  assert_true(prepared_html.contains("local-commit-abc"))
  assert_true(prepared_html.contains("确认提交 PR"))
  let review_item : BatchItem = {
    ..item,
    key: "moonbitlang--review",
    needs_review: true,
  }
  let review_html = @rabbita.render_to_string(fn() {
    Val::constant(
      batch_view(
        {
          ..batch,
          detail: { ..batch.detail, items: [review_item] },
          selected_item: review_item.key,
        },
        "light",
        emit,
      ),
    )
  })
  assert_true(review_html.contains("需人工确认"))
  assert_true(review_html.contains("确认放行"))
}

///|
test "batch activity decode keeps agent tool events readable" {
  let entry = decode_batch_activity(
    "{\"kind\":\"agent_event\",\"item_key\":\"acme--demo\",\"timestamp_ms\":1787078266478,\"message\":\"调用工具 read_file\",\"data\":{\"type\":\"tool_started\",\"tool\":\"read_file\"}}",
  )
  guard entry is Some(value) else { fail("expected activity entry") }
  assert_eq(value.kind, "agent_event")
  assert_eq(value.tool, "read_file")
  assert_eq(value.message, "调用工具 read_file")
  assert_eq(batch_activity_class(value.kind), "agent")
  let item_entry = decode_batch_activity(
    "{\"kind\":\"item_state\",\"item_key\":\"acme--demo\",\"timestamp_ms\":1,\"message\":\"\",\"data\":{\"status\":\"fixing\"}}",
  )
  guard item_entry is Some(item) else { fail("expected item entry") }
  assert_eq(item.status, "fixing")
  assert_eq(batch_activity_label(item), "包任务：修复中")
  assert_true(item.timestamp != "")
}

///|
test "new conversation waits for a chosen workspace before creating the session" {
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let entry : WorkspaceEntry = {
    id: "ws-1",
    name: "Demo",
    path: "D:/demo",
    kind: "local",
    mode: "local",
    managed: false,
    lifecycle: "local",
    branch: "main",
    detached: false,
    pinned: false,
    status: "ready",
    revision: "rev",
    source_id: "",
    owner_task_id: "",
    owner_session_id: "",
    eligible_for_cleanup: false,
  }
  let model = {
    ..test_model([{ id: "s1", title: "S1", detail: "", messages: [] }], 0, Idle),
    workspace: {
      ..initial_workspace(),
      entries: [entry],
      id: "ws-1",
      name: "Demo",
    },
  }
  // 新对话只打开工作区面板，不直接创建会话。
  let (pending, _) = update(model, NewSession, emit)
  assert_true(pending.pending_new_session)
  assert_true(pending.workspace.open)
  assert_eq(pending.sessions.length(), 1)

  // 关闭面板会取消待创建的新对话。
  let (cancelled, _) = update(pending, ToggleWorkspace, emit)
  assert_false(cancelled.pending_new_session)
  assert_false(cancelled.workspace.open)
  assert_eq(cancelled.sessions.length(), 1)

  // 选择已注册的工作区后创建新会话并绑定。
  let (chosen, _) = update(pending, WorkspaceSelect("ws-1"), emit)
  assert_false(chosen.pending_new_session)
  assert_eq(chosen.sessions.length(), 2)
  assert_eq(chosen.workspace.id, "ws-1")
  assert_eq(
    chosen.workspace.session_id,
    chosen.sessions[chosen.active_session].id,
  )

  // 通过目录选择器新建工作区也会触发新对话。
  let picked_model = {
    ..model,
    pending_new_session: true,
    workspace: { ..model.workspace, open: true },
  }
  let (picked, _) = update(
    picked_model,
    WorkspacePicked("{\"workspace\":{\"id\":\"ws-2\",\"name\":\"Picked\"}}"),
    emit,
  )
  assert_false(picked.pending_new_session)
  assert_eq(picked.workspace.id, "ws-2")
  assert_eq(picked.sessions.length(), 2)
}
