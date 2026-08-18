///|
/// An incremental tool-call fragment inside a streaming chunk.
struct ToolCallDelta {
  index : Int
  id : String?
  name : String?
  arguments : String?
} derive(Eq, Debug)

///|
/// A parsed delta from one streaming chat completion chunk.
struct StreamChunk {
  content : String?
  reasoning_content : String?
  tool_calls : Array[ToolCallDelta]
  finish_reason : String?
} derive(Eq, Debug)

///|
/// One classified SSE line coming out of the response body.
enum SseEvent {
  Data(String)
  Done
  Skip
} derive(Eq, Debug)

///|
/// Classify a raw SSE line. `read_until("\n")` already strips the newline,
/// but CRLF leaves a trailing `\r` that must be removed.
fn parse_sse_line(line : String) -> SseEvent {
  let mut end = line.length()
  if end > 0 && line[end - 1] == '\r' {
    end = end - 1
  }
  let trimmed = line[:end].to_owned()
  if trimmed.length() == 0 || trimmed.has_prefix(":") {
    return Skip
  }
  match trimmed.find(":") {
    Some(idx) => {
      let field = trimmed[:idx].to_owned()
      if field != "data" {
        return Skip
      }
      let mut value = trimmed[idx + 1:].to_owned()
      // SSE allows a single optional space after the colon.
      if value.has_prefix(" ") {
        value = value[1:].to_owned()
      }
      if value == "[DONE]" {
        Done
      } else {
        Data(value)
      }
    }
    None => Skip
  }
}

///|
/// Parse one SSE `data:` payload (the JSON after `data: `) into a `StreamChunk`.
/// Returns `None` for chunks that carry no usable delta (e.g. role-only
/// opening chunks) and for malformed JSON.
fn parse_stream_chunk(payload : String) -> StreamChunk? {
  let document = @json.parse(payload) catch { _ => return None }
  guard document is Object(fields) else { return None }
  guard fields.get("choices") is Some(Array(choices)) else { return None }
  guard choices.get(0) is Some(Object(choice)) else { return None }
  let delta = match choice.get("delta") {
    Some(Object(d)) => d
    _ => {}
  }
  let content = match delta.get("content") {
    Some(String(s)) => Some(s)
    _ => None
  }
  // DeepSeek reasoner 系列通过 reasoning_content 增量返回思考过程。
  let reasoning_content = match delta.get("reasoning_content") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let tool_calls = parse_tool_call_deltas(delta)
  let finish_reason = match choice.get("finish_reason") {
    Some(String(s)) => Some(s)
    _ => None
  }
  if content is None &&
    reasoning_content is None &&
    tool_calls.is_empty() &&
    finish_reason is None {
    return None
  }
  Some({ content, reasoning_content, tool_calls, finish_reason })
}

///|
/// Extract tool-call fragments from a streaming `delta` object.
fn parse_tool_call_deltas(delta : Map[String, Json]) -> Array[ToolCallDelta] {
  let out : Array[ToolCallDelta] = []
  guard delta.get("tool_calls") is Some(Array(items)) else { return out }
  for item in items {
    guard item is Object(tc) else { continue }
    let index = match tc.get("index") {
      Some(Number(n, ..)) => n.to_int()
      _ => 0
    }
    let id = match tc.get("id") {
      Some(String(s)) => Some(s)
      _ => None
    }
    let (name, arguments) = match tc.get("function") {
      Some(Object(f)) => {
        let name = match f.get("name") {
          Some(String(s)) => Some(s)
          _ => None
        }
        let arguments = match f.get("arguments") {
          Some(String(s)) => Some(s)
          _ => None
        }
        (name, arguments)
      }
      _ => (None, None)
    }
    out.push({ index, id, name, arguments })
  }
  out
}

///|
/// A complete tool call assembled from streamed fragments.
pub(all) struct ChatToolCall {
  id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
priv struct ToolCallBuilder {
  mut id : String
  mut name : String
  arguments : StringBuilder
}

///|
/// Accumulates streaming tool-call fragments into complete calls.
priv struct ToolCallAccumulator {
  by_index : Map[Int, ToolCallBuilder]
  order : Array[Int]
}

///|
fn ToolCallAccumulator::new() -> ToolCallAccumulator {
  { by_index: {}, order: [] }
}

///|
fn ToolCallAccumulator::add(
  self : ToolCallAccumulator,
  deltas : Array[ToolCallDelta],
) -> Unit {
  for delta in deltas {
    let builder = match self.by_index.get(delta.index) {
      Some(b) => b
      None => {
        let b : ToolCallBuilder = {
          id: "",
          name: "",
          arguments: StringBuilder::new(),
        }
        self.by_index[delta.index] = b
        self.order.push(delta.index)
        b
      }
    }
    if delta.id is Some(id) {
      builder.id = id
    }
    if delta.name is Some(name) {
      builder.name = name
    }
    if delta.arguments is Some(args) {
      builder.arguments.write_string(args)
    }
  }
}

///|
fn ToolCallAccumulator::finish(
  self : ToolCallAccumulator,
) -> Array[ChatToolCall] {
  let out : Array[ChatToolCall] = []
  for idx in self.order {
    if self.by_index.get(idx) is Some(b) {
      out.push({ id: b.id, name: b.name, arguments: b.arguments.to_string() })
    }
  }
  out
}

///|
/// The complete result of a streaming chat completion.
pub(all) struct StreamResult {
  content : String
  reasoning_content : String
  tool_calls : Array[ChatToolCall]
  finish_reason : String?
}

///|
pub async fn ignore_delta(_ : String) -> Unit {
  @async.sleep(0)
}

///|
pub async fn ignore_retry(_attempt : Int, _reason : String) -> Unit {
  @async.sleep(0)
}

///|
// Forward only the suffix that has not already been shown by an earlier
// attempt. A retry must reproduce the emitted prefix exactly; otherwise
// continuing would splice two different model responses together.
async fn forward_new_delta(
  aggregate : String,
  emitted : StringBuilder,
  callback : async (String) -> Unit,
) -> Unit {
  let previous = emitted.to_string()
  if aggregate.length() <= previous.length() {
    guard previous.has_prefix(aggregate) else {
      fail("LLM API retry diverged from the partial response already emitted")
    }
    return
  }
  guard aggregate.has_prefix(previous) else {
    fail("LLM API retry diverged from the partial response already emitted")
  }
  let suffix = aggregate[previous.length():].to_owned()
  emitted.write_string(suffix)
  callback(suffix)
}

///|
// One streaming request attempt. Retryable failures use an internal marker;
// the caller applies bounded backoff. Partial output is safe to retry because
// forward_new_delta suppresses the prefix already shown to the user.
async fn attempt_chat_completion(
  provider : ProviderKind,
  api_key : String,
  base_url : String,
  model : String,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens : Int,
  on_delta : async (String) -> Unit,
  on_reasoning : async (String) -> Unit,
  connect_timeout_ms : Int,
  stream_idle_timeout_ms : Int,
  emitted_content : StringBuilder,
  emitted_reasoning : StringBuilder,
) -> StreamResult {
  let (endpoint, headers) = match provider {
    OpenAi =>
      (
        base_url.trim_end(chars="/").to_owned() + "/chat/completions",
        {
          "Authorization": "Bearer " + api_key,
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
        },
      )
    Anthropic =>
      (
        base_url.trim_end(chars="/").to_owned() + "/v1/messages",
        {
          "x-api-key": api_key,
          "anthropic-version": "2023-06-01",
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
        },
      )
    Ollama =>
      (
        base_url.trim_end(chars="/").to_owned() + "/api/chat",
        { "Content-Type": "application/json" },
      )
  }
  let payload : Map[String, Json] = match provider {
    OpenAi =>
      {
        "model": Json::string(model),
        "messages": Json::array(messages),
        "stream": Json::boolean(true),
        "max_tokens": Json::number(max_tokens.to_double()),
      }
    Anthropic =>
      {
        "model": Json::string(model),
        "max_tokens": Json::number(max_tokens.to_double()),
        "stream": Json::boolean(true),
        "system": Json::string(anthropic_system(messages)),
        "messages": Json::array(anthropic_messages(messages)),
      }
    Ollama =>
      {
        "model": Json::string(model),
        "messages": Json::array(messages),
        "stream": Json::boolean(true),
        "options": Json::object({
          "num_predict": Json::number(max_tokens.to_double()),
        }),
      }
  }
  if tools.length() > 0 {
    payload["tools"] = match provider {
      Anthropic => Json::array(anthropic_tools(tools))
      _ => Json::array(tools)
    }
  }
  let request = Json::object(payload)
  let client = @async.with_timeout(connect_timeout_ms, () => {
    @http.post_stream(endpoint, headers~)
  }) catch {
    @async.TimeoutError(_) =>
      fail("retryable: LLM API connect timed out (\{connect_timeout_ms} ms)")
    err => fail("retryable: LLM API connect failed: \{err.to_string()}")
  }
  defer client.close()
  let response = @async.with_timeout(connect_timeout_ms, () => {
    client..write(request.stringify()).end_request()
  }) catch {
    @async.TimeoutError(_) =>
      fail("retryable: LLM API request timed out (\{connect_timeout_ms} ms)")
    err => fail("retryable: LLM API request failed: \{err.to_string()}")
  }
  guard response.code >= 200 && response.code < 300 else {
    let detail = @async.with_timeout(5000, () => {
      client.read_all().binary().to_string()
    }) catch {
      _ => ""
    }
    let retryable = response.code == 429 ||
      (response.code >= 500 && response.code < 600)
    if retryable {
      fail("retryable: LLM API returned HTTP \{response.code}: \{detail}")
    } else {
      fail("LLM API returned HTTP \{response.code}: \{detail}")
    }
  }
  let content = StringBuilder::new()
  let reasoning = StringBuilder::new()
  let accumulator = ToolCallAccumulator::new()
  let mut finish_reason : String? = None
  let mut completed = false
  for ;; {
    let line = @async.with_timeout(stream_idle_timeout_ms, () => {
      client.read_until("\n")
    }) catch {
      @async.TimeoutError(_) =>
        fail(
          "retryable: LLM API stream idle timed out (\{stream_idle_timeout_ms} ms)",
        )
      err => fail("retryable: LLM API stream read failed: \{err.to_string()}")
    }
    match line {
      None =>
        if completed {
          break
        } else {
          fail("retryable: LLM API stream closed before completion")
        }
      Some(line) =>
        match parse_sse_line(line) {
          Skip => ()
          Done => {
            completed = true
            break
          }
          Data(payload) => {
            let chunk = match provider {
              OpenAi => parse_stream_chunk(payload)
              Anthropic => parse_anthropic_chunk(payload)
              Ollama => parse_ollama_chunk(payload)
            }
            if chunk is Some(chunk) {
              if chunk.content is Some(text) {
                content.write_string(text)
                forward_new_delta(
                  content.to_string(),
                  emitted_content,
                  on_delta,
                )
              }
              if chunk.reasoning_content is Some(text) {
                reasoning.write_string(text)
                forward_new_delta(
                  reasoning.to_string(),
                  emitted_reasoning,
                  on_reasoning,
                )
              }
              if chunk.finish_reason is Some(reason) {
                finish_reason = Some(reason)
                completed = true
              }
              accumulator.add(chunk.tool_calls)
            }
          }
        }
    }
  }
  let final_content = content.to_string()
  let final_reasoning = reasoning.to_string()
  guard final_content == emitted_content.to_string() &&
    final_reasoning == emitted_reasoning.to_string() else {
    fail("LLM API retry ended before reproducing the partial response")
  }
  {
    content: final_content,
    reasoning_content: final_reasoning,
    tool_calls: accumulator.finish(),
    finish_reason,
  }
}

///|
/// Stream a chat completion over HTTP using SSE, invoking `on_delta` with each
/// incremental text fragment as it arrives. Transient failures (network /
/// connect timeout / HTTP 429 / HTTP 5xx) are retried with a fixed backoff
/// until `max_retries` is exhausted; errors raised after streaming has
/// started are retried without emitting the same prefix twice.
pub async fn stream_chat_completion_provider(
  provider : ProviderKind,
  api_key : String,
  base_url : String,
  model : String,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens? : Int = 1200,
  on_delta? : async (String) -> Unit = ignore_delta,
  on_reasoning? : async (String) -> Unit = ignore_delta,
  on_retry? : async (Int, String) -> Unit = ignore_retry,
  connect_timeout_ms? : Int = 30000,
  stream_idle_timeout_ms? : Int = 60000,
  max_retries? : Int = 2,
  retry_delay_ms? : Int = 500,
) -> StreamResult {
  let mut retries_left = max_retries
  let mut attempt = 0
  let emitted_content = StringBuilder::new()
  let emitted_reasoning = StringBuilder::new()
  let mut result : StreamResult = {
    content: "",
    reasoning_content: "",
    tool_calls: [],
    finish_reason: None,
  }
  let mut done = false
  while !done {
    attempt += 1
    try {
      result = attempt_chat_completion(
        provider, api_key, base_url, model, messages, tools, max_tokens, on_delta,
        on_reasoning, connect_timeout_ms, stream_idle_timeout_ms, emitted_content,
        emitted_reasoning,
      )
      done = true
    } catch {
      e => {
        let message = e.to_string()
        // Failure 的 to_string 会带源位置与 "FAILED: " 前缀,因此用 contains 判断。
        let marker = "retryable: "
        if retries_left > 0 && message.contains(marker) {
          retries_left = retries_left - 1
          let reason = match message.find(marker) {
            Some(idx) => message[idx + marker.length():].to_owned()
            None => message
          }
          on_retry(attempt, reason)
          @async.sleep(retry_delay_ms)
        } else if message.contains(marker) {
          // 重试耗尽:剥掉内部标记,避免用户看到 "retryable:" 前缀。
          match message.find(marker) {
            Some(idx) => fail(message[idx + marker.length():])
            None => raise e
          }
        } else {
          raise e
        }
      }
    }
  }
  result
}

///|
/// Stream a chat completion through the OpenAI-compatible protocol
/// (the default provider).
pub async fn stream_chat_completion(
  api_key : String,
  base_url : String,
  model : String,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens? : Int = 1200,
  on_delta? : async (String) -> Unit = ignore_delta,
  on_reasoning? : async (String) -> Unit = ignore_delta,
  on_retry? : async (Int, String) -> Unit = ignore_retry,
  connect_timeout_ms? : Int = 30000,
  stream_idle_timeout_ms? : Int = 60000,
  max_retries? : Int = 2,
  retry_delay_ms? : Int = 500,
) -> StreamResult {
  stream_chat_completion_provider(
    OpenAi,
    api_key,
    base_url,
    model,
    messages,
    tools,
    max_tokens~,
    on_delta~,
    on_reasoning~,
    on_retry~,
    connect_timeout_ms~,
    stream_idle_timeout_ms~,
    max_retries~,
    retry_delay_ms~,
  )
}

///|
pub fn chat_message(role : String, content : String) -> Json {
  Json::object({ "role": Json::string(role), "content": Json::string(content) })
}

///|
pub fn assistant_message_with_tool_calls(
  content : String,
  calls : Array[ChatToolCall],
) -> Json {
  let tool_calls : Array[Json] = []
  for call in calls {
    tool_calls.push(
      Json::object({
        "id": Json::string(call.id),
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(call.name),
          "arguments": Json::string(call.arguments),
        }),
      }),
    )
  }
  Json::object({
    "role": Json::string("assistant"),
    "content": Json::string(content),
    "tool_calls": Json::array(tool_calls),
  })
}

///|
pub fn tool_result_message(tool_call_id : String, result : String) -> Json {
  Json::object({
    "role": Json::string("tool"),
    "tool_call_id": Json::string(tool_call_id),
    "content": Json::string(result),
  })
}
