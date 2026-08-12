///|
fn demo_reply(prompt : String) -> String {
  "## 已收到\n\nMoonSage 已通过前端适配器接收这条消息：\n\n```text\n\{prompt}\n```\n\n- 会话状态已保留\n- Markdown 渲染已启用\n- 真实 Agent API 尚待接入"
}

///|
fn request_agent(emit : Emit[Msg], session_id : String, prompt : String) -> Cmd {
  @rabbita.delay(emit(AgentReplied(session_id, demo_reply(prompt))), 650)
}

///|
fn simulate_failure(
  emit : Emit[Msg],
  session_id : String,
  prompt : String,
) -> Cmd {
  @rabbita.delay(
    emit(
      AgentFailed(
        session_id, prompt, "演示适配器主动返回了一个可重试错误。",
      ),
    ),
    650,
  )
}
