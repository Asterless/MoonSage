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
