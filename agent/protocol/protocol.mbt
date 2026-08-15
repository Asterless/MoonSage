///|
/// Encode one runtime event using the canonical CLI/Web JSONL protocol.
pub fn event_to_json(event : @runtime.EngineEvent) -> Json {
  match event {
    ThinkingDelta(event) =>
      Json::object({
        "type": Json::string("thinking_delta"),
        "round": Json::number(event.round.to_double()),
        "text": Json::string(event.text),
      })
    ToolStarted(event) =>
      Json::object({
        "type": Json::string("tool_started"),
        "round": Json::number(event.round.to_double()),
        "call_id": Json::string(event.call_id),
        "name": Json::string(event.name),
        "arguments": Json::string(event.arguments),
      })
    ToolFinished(event) =>
      Json::object({
        "type": Json::string("tool_finished"),
        "round": Json::number(event.round.to_double()),
        "call_id": Json::string(event.call_id),
        "name": Json::string(event.name),
        "status": Json::string(event.status),
        "result": Json::string(event.result),
      })
    FinalStarted => Json::object({ "type": Json::string("final_started") })
    FinalDelta(text) =>
      Json::object({
        "type": Json::string("final_delta"),
        "text": Json::string(text),
      })
    Retrying(event) =>
      Json::object({
        "type": Json::string("retrying"),
        "attempt": Json::number(event.attempt.to_double()),
        "reason": Json::string(event.reason),
      })
    Warning(message) =>
      Json::object({
        "type": Json::string("warning"),
        "message": Json::string(message),
      })
    Error(message) =>
      Json::object({
        "type": Json::string("error"),
        "message": Json::string(message),
      })
  }
}
