///|
test "async replies stay with their originating session" {
  let model : Model = {
    draft: "",
    sessions: [
      { id: "origin", title: "Origin", detail: "", messages: [] },
      { id: "active", title: "Active", detail: "", messages: [] },
    ],
    active_session: 1,
    request: Idle,
    command_open: false,
    sidebar_open: true,
    workspace: initial_workspace(),
  }
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
  let model : Model = {
    draft: "",
    sessions: [
      { id: "origin", title: "Origin", detail: "", messages: [] },
      { id: "active", title: "Active", detail: "", messages: [] },
    ],
    active_session: 1,
    request: Sending("origin", "question", "正在分析问题", "first"),
    command_open: false,
    sidebar_open: true,
    workspace: initial_workspace(),
  }
  let emit : Emit[Msg] = Emit(_ => @rabbita.none)
  let (streamed, _) = update(model, AgentDelta("origin", " second"), emit)
  assert_true(
    streamed.request is Sending("origin", "question", _, "first second"),
  )
  let (unchanged, _) = update(streamed, AgentDelta("active", "wrong"), emit)
  assert_true(unchanged == streamed)
  let (failed, _) = update(
    streamed,
    AgentFailed("active", "question", "stale failure"),
    emit,
  )
  assert_true(failed == streamed)
}

///|
test "Agent responses decode success and service errors" {
  assert_eq(
    decode_agent_event("{\"type\":\"delta\",\"text\":\"真实回答\"}"),
    Delta("真实回答"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"status\",\"message\":\"正在搜索\"}"),
    Status("正在搜索"),
  )
  assert_eq(
    decode_agent_event("{\"type\":\"error\",\"message\":\"missing key\"}"),
    StreamError("missing key"),
  )
  assert_true(decode_agent_event("not json") is Ignored)
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
