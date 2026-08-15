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
// The server streams one JSON object per line. Canonical CLI events are
// decoded first; legacy browser aliases remain accepted during migration.
enum AgentStreamEvent {
  Status(String)
  Delta(String)
  Thinking(String)
  Meta(Bool)
  ToolStarted(String, String, String, Int)
  ToolFinished(String, String, String, Int)
  Retry(Int, String)
  Warning(String)
  Done
  StreamError(String)
  Ignored
} derive(Debug, Eq)

///|
fn agent_call_id(fields : Map[String, Json]) -> String {
  match fields.get("call_id") {
    Some(String(call_id)) => call_id
    _ => json_string_field(fields, "id")
  }
}

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
    Some(String("final_started")) => Status("正在组织回答")
    Some(String("final_delta")) =>
      match fields.get("text") {
        Some(String(text)) => Delta(text)
        _ => Ignored
      }
    Some(String("delta")) =>
      match fields.get("text") {
        Some(String(text)) => Delta(text)
        _ => Ignored
      }
    Some(String("thinking_delta")) =>
      match fields.get("text") {
        Some(String(text)) => Thinking(text)
        _ => Ignored
      }
    Some(String("thinking")) =>
      match fields.get("text") {
        Some(String(text)) => Thinking(text)
        _ => Ignored
      }
    Some(String("meta")) =>
      match fields.get("history_truncated") {
        Some(True) => Meta(true)
        Some(False) => Meta(false)
        _ => Ignored
      }
    Some(String("tool_started")) =>
      match fields.get("name") {
        Some(String(name)) =>
          ToolStarted(
            agent_call_id(fields),
            name,
            json_string_field(fields, "arguments"),
            json_int_field(fields, "round", 0),
          )
        _ => Ignored
      }
    Some(String("tool_finished")) =>
      match fields.get("name") {
        Some(String(_)) =>
          ToolFinished(
            agent_call_id(fields),
            json_string_field(fields, "status"),
            json_string_field(fields, "result"),
            json_int_field(fields, "round", 0),
          )
        _ => Ignored
      }
    Some(String("retrying")) =>
      Retry(
        json_int_field(fields, "attempt", 0),
        json_string_field(fields, "reason"),
      )
    Some(String("retry")) =>
      Retry(
        json_int_field(fields, "attempt", 0),
        json_string_field(fields, "reason"),
      )
    Some(String("warning")) =>
      match fields.get("message") {
        Some(String(message)) => Warning(message)
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
// Streaming request with an AbortController so the user can stop the agent
// mid-flight. The controller is parked on globalThis because MoonBit extern
// functions do not share module-level JS state; abort_agent_request reaches it.
extern "js" fn stream_agent_request(
  body : String,
  on_line : (String) -> Unit,
  failed : (String) -> Unit,
  aborted : () -> Unit,
) -> Unit =
  #| (body, onLine, failed, aborted) => {
  #|   globalThis.__moonsageAgentAbort?.abort();
  #|   const controller = new AbortController();
  #|   globalThis.__moonsageAgentAbort = controller;
  #|   void (async () => {
  #|     try {
  #|       const response = await fetch("/api/agent", {
  #|         method: "POST",
  #|         headers: { "Content-Type": "application/json" },
  #|         body,
  #|         signal: controller.signal,
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
  #|       if (error && error.name === "AbortError") aborted();
  #|       else failed(error instanceof Error ? error.message : String(error));
  #|     } finally {
  #|       if (globalThis.__moonsageAgentAbort === controller) globalThis.__moonsageAgentAbort = null;
  #|     }
  #|   })();
  #| }

///|
extern "js" fn abort_agent_request() -> Unit =
  #| () => {
  #|   globalThis.__moonsageAgentAbort?.abort();
  #|   globalThis.__moonsageAgentAbort = null;
  #| }

///|
// Keep the message list pinned to the bottom while streaming, but only when
// the user is already near the bottom so reading history is not interrupted.
extern "js" fn stick_to_bottom_if_near() -> Unit =
  #| () => {
  #|   const scroller = document.querySelector(".message-scroll");
  #|   if (!scroller) return;
  #|   const distance = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
  #|   if (distance < 180) scroller.scrollTop = scroller.scrollHeight;
  #| }

///|
fn after_render_scroll() -> Cmd {
  @cmd.custom_cmd(_ => stick_to_bottom_if_near(), kind=@cmd.AfterRender)
}

///|
fn request_agent(
  emit : Emit[Msg],
  session_id : String,
  request_id : Int,
  messages : Array[Message],
) -> Cmd {
  let body = agent_request_body(session_id, messages).stringify()
  @cmd.custom_cmd(scheduler => {
    stream_agent_request(
      body,
      line => {
        let command = match decode_agent_event(line) {
          Status(message) => emit(AgentStatus(request_id, message))
          Delta(text) => emit(AgentDelta(request_id, text))
          Thinking(text) => emit(AgentThinking(request_id, text))
          Meta(truncated) => emit(AgentMeta(request_id, truncated))
          ToolStarted(call_id, name, arguments, round) =>
            emit(AgentToolStarted(request_id, call_id, name, arguments, round))
          ToolFinished(call_id, status, result, _) =>
            emit(AgentToolFinished(request_id, call_id, status, result))
          Retry(attempt, reason) =>
            emit(AgentRetry(request_id, attempt, reason))
          Warning(message) => emit(AgentWarning(request_id, message))
          Done => emit(AgentFinished(request_id))
          StreamError(reason) => emit(AgentFailed(request_id, reason))
          Ignored => @rabbita.none
        }
        scheduler.add(command)
      },
      reason => scheduler.add(emit(AgentFailed(request_id, reason))),
      () => scheduler.add(emit(AgentStopped(request_id))),
    )
  })
}
