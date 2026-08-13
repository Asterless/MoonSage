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
