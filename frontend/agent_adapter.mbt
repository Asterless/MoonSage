///|
fn agent_request_body(session_id : String, messages : Array[Message]) -> Json {
  Json::object({
    "session_id": Json::string(session_id),
    "messages": Json::array(
      messages.map(message => {
        Json::object({
          "role": Json::string(message.role),
          "text": Json::string(message.text),
        })
      }),
    ),
  })
}

///|
fn decode_agent_response(body : String) -> Result[String, String] {
  let document = @json.parse(body) catch {
    _ => return Err("Agent 服务返回了无法解析的响应。")
  }
  guard document is Object(fields) else {
    return Err("Agent 服务返回格式不正确。")
  }
  match fields.get("answer") {
    Some(String(answer)) if answer.trim() != "" => Ok(answer)
    _ =>
      match fields.get("error") {
        Some(String(message)) if message.trim() != "" => Err(message)
        _ => Err("Agent 服务没有返回内容。")
      }
  }
}

///|
fn request_agent(
  emit : Emit[Msg],
  session_id : String,
  prompt : String,
  messages : Array[Message],
) -> Cmd {
  @http.post("/api/agent")
  .with_json(agent_request_body(session_id, messages))
  .expect_text(result => {
    match result {
      Ok(body) =>
        match decode_agent_response(body) {
          Ok(answer) => emit(AgentReplied(session_id, answer))
          Err(reason) => emit(AgentFailed(session_id, prompt, reason))
        }
      Err(error) => emit(AgentFailed(session_id, prompt, error.to_string()))
    }
  })
}
