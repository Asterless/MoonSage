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
    workspace: initial_workspace(),
    next_id: 100,
  }
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
  assert_true(decode_agent_event("not json") is Ignored)
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
    decode_workspace_tree(
      "{\"root\":\"demo\",\"files\":[\"main.mbt\",\"src/lib.mbt\"]}",
    ),
    Some(("demo", ["main.mbt", "src/lib.mbt"])),
  )
  assert_eq(
    decode_workspace_file("{\"content\":\"a\",\"line_endings\":\"crlf\"}"),
    Some(("a", "crlf")),
  )
  let workspace = initial_workspace()
  guard apply_workspace_status(
      workspace, "{\"branch\":\"codex/workspace\",\"changes\":[{\"path\":\"main.mbt\",\"index\":\"M\",\"worktree\":\" \",\"staged\":true,\"unstaged\":false,\"untracked\":false}]}",
    )
    is Some(updated) else {
    fail("expected workspace status")
  }
  assert_eq(updated.branch, "codex/workspace")
  assert_eq(updated.changes.length(), 1)
  assert_true(updated.changes[0].staged)
}

///|
test "workspace protects unsaved editor state from stale saves" {
  let workspace = {
    ..initial_workspace(),
    selected_path: "main.mbt",
    content: "newer",
    saved_content: "old",
    loading: true,
  }
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  guard workspace_update(
      workspace,
      WorkspaceFileSaved("main.mbt", "older request"),
      emit,
    )
    is Some((updated, _)) else {
    fail("expected workspace update")
  }
  assert_eq(updated.content, "newer")
  assert_eq(updated.saved_content, "old")
  assert_true(workspace_changed(updated))
}
