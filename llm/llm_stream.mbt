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
  let tool_calls = parse_tool_call_deltas(delta)
  let finish_reason = match choice.get("finish_reason") {
    Some(String(s)) => Some(s)
    _ => None
  }
  if content is None && tool_calls.is_empty() && finish_reason is None {
    return None
  }
  Some({ content, tool_calls, finish_reason })
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
  tool_calls : Array[ChatToolCall]
  finish_reason : String?
}

///|
pub async fn ignore_delta(_ : String) -> Unit {
  @async.sleep(0)
}

///|
/// Stream a chat completion over HTTP using SSE, invoking `on_delta` with each
/// incremental text fragment as it arrives. Returns the fully assembled result.
pub async fn stream_chat_completion(
  api_key : String,
  base_url : String,
  model : String,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens? : Int = 1200,
  on_delta? : async (String) -> Unit = ignore_delta,
) -> StreamResult {
  let endpoint = base_url.trim_end(chars="/").to_owned() + "/chat/completions"
  let request = Json::object({
    "model": Json::string(model),
    "messages": Json::array(messages),
    "stream": Json::boolean(true),
    "max_tokens": Json::number(max_tokens.to_double()),
    "tools": Json::array(tools),
  })
  let headers = {
    "Authorization": "Bearer " + api_key,
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
  }
  let client = @http.post_stream(endpoint, headers~)
  defer client.close()
  let response = client..write(request.stringify()).end_request()
  guard response.code >= 200 && response.code < 300 else {
    let detail = client.read_all().binary().to_string() catch { _ => "" }
    fail("LLM API returned HTTP \{response.code}: \{detail}")
  }
  let content = StringBuilder::new()
  let accumulator = ToolCallAccumulator::new()
  let mut finish_reason : String? = None
  for ;; {
    match client.read_until("\n") {
      None => break
      Some(line) =>
        match parse_sse_line(line) {
          Skip => ()
          Done => break
          Data(payload) => {
            let chunk = parse_stream_chunk(payload)
            if chunk is Some(chunk) {
              if chunk.content is Some(text) {
                content.write_string(text)
                on_delta(text)
              }
              if chunk.finish_reason is Some(reason) {
                finish_reason = Some(reason)
              }
              accumulator.add(chunk.tool_calls)
            }
          }
        }
    }
  }
  {
    content: content.to_string(),
    tool_calls: accumulator.finish(),
    finish_reason,
  }
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
