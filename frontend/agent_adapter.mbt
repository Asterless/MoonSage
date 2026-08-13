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
enum AgentStreamEvent {
  Status(String)
  Delta(String)
  Done
  StreamError(String)
  Ignored
} derive(Debug, Eq)

///|
fn decode_agent_event(line : String) -> AgentStreamEvent {
  let document = @json.parse(line) catch { _ => return Ignored }
  guard document is Object(fields) else { return Ignored }
  match fields.get("type") {
    Some(String("status")) =>
      match fields.get("message") {
        Some(String(message)) => Status(message)
        _ => Ignored
      }
    Some(String("delta")) =>
      match fields.get("text") {
        Some(String(text)) => Delta(text)
        _ => Ignored
      }
    Some(String("done")) => Done
    Some(String("error")) =>
      match fields.get("message") {
        Some(String(message)) => StreamError(message)
        _ => StreamError("Agent 请求失败。")
      }
    _ =>
      match fields.get("error") {
        Some(String(message)) => StreamError(message)
        _ => Ignored
      }
  }
}

///|
extern "js" fn stream_agent_request(
  body : String,
  on_line : (String) -> Unit,
  failed : (String) -> Unit,
) -> Unit =
  #| (body, onLine, failed) => {
  #|   void (async () => {
  #|     try {
  #|       const response = await fetch("/api/agent", {
  #|         method: "POST",
  #|         headers: { "Content-Type": "application/json" },
  #|         body,
  #|       });
  #|       if (!response.ok) throw new Error(`HTTP ${response.status}`);
  #|       if (!response.body) throw new Error("浏览器不支持流式响应");
  #|       const reader = response.body.getReader();
  #|       const decoder = new TextDecoder();
  #|       let pending = "";
  #|       while (true) {
  #|         const { value, done } = await reader.read();
  #|         pending += decoder.decode(value || new Uint8Array(), { stream: !done });
  #|         const lines = pending.split(/\r?\n/);
  #|         pending = lines.pop() || "";
  #|         for (const line of lines) if (line.trim()) onLine(line);
  #|         if (done) break;
  #|       }
  #|       if (pending.trim()) onLine(pending);
  #|     } catch (error) {
  #|       failed(error instanceof Error ? error.message : String(error));
  #|     }
  #|   })();
  #| }

///|
fn request_agent(
  emit : Emit[Msg],
  session_id : String,
  prompt : String,
  messages : Array[Message],
) -> Cmd {
  let body = agent_request_body(session_id, messages).stringify()
  @cmd.custom_cmd(scheduler => {
    stream_agent_request(
      body,
      line => {
        let command = match decode_agent_event(line) {
          Status(message) => emit(AgentStatus(session_id, message))
          Delta(text) => emit(AgentDelta(session_id, text))
          Done => emit(AgentFinished(session_id, prompt))
          StreamError(reason) => emit(AgentFailed(session_id, prompt, reason))
          Ignored => @rabbita.none
        }
        scheduler.add(command)
      },
      reason => scheduler.add(emit(AgentFailed(session_id, prompt, reason))),
    )
  })
}
