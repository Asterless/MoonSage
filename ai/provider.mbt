///|
/// Which chat-completion protocol the LLM layer talks to.
pub(all) enum ProviderKind {
  OpenAi
  Anthropic
  Ollama
}

///|
pub fn provider_from_string(s : String) -> ProviderKind {
  let v = s.trim().to_owned()
  if v == "anthropic" || v == "Anthropic" {
    Anthropic
  } else if v == "ollama" || v == "Ollama" {
    Ollama
  } else {
    OpenAi
  }
}

///|
pub fn provider_to_string(kind : ProviderKind) -> String {
  match kind {
    OpenAi => "openai"
    Anthropic => "anthropic"
    Ollama => "ollama"
  }
}

///|
// Parse one Ollama /api/chat streaming `data:` payload. Shapes:
//   {"message":{"role":"assistant","content":"hi"},"done":false}
//   {"message":{"tool_calls":[{"function":{"name":"f","arguments":{...}}}]},"done":false}
//   {"done":true,"done_reason":"stop"}
pub fn parse_ollama_chunk(payload : String) -> StreamChunk? {
  let document = @json.parse(payload) catch { _ => return None }
  guard document is Object(fields) else { return None }
  let done = match fields.get("done") {
    Some(True) => true
    _ => false
  }
  if done {
    let finish = match fields.get("done_reason") {
      Some(String(s)) => Some(s)
      _ => None
    }
    return Some({
      content: None,
      reasoning_content: None,
      tool_calls: [],
      finish_reason: finish,
    })
  }
  guard fields.get("message") is Some(Object(msg)) else { return None }
  let content = match msg.get("content") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let tool_calls = parse_ollama_tool_calls(msg)
  if content is None && tool_calls.is_empty() {
    return None
  }
  Some({ content, reasoning_content: None, tool_calls, finish_reason: None })
}

///|
fn parse_ollama_tool_calls(msg : Map[String, Json]) -> Array[ToolCallDelta] {
  let out : Array[ToolCallDelta] = []
  guard msg.get("tool_calls") is Some(Array(items)) else { return out }
  for i = 0; i < items.length(); i = i + 1 {
    guard items[i] is Object(tc) else { continue }
    let name = match tc.get("function") {
      Some(Object(f)) =>
        match f.get("name") {
          Some(String(n)) => n
          _ => ""
        }
      _ => ""
    }
    let arguments = match tc.get("function") {
      Some(Object(f)) =>
        match f.get("arguments") {
          Some(arg) => arg.stringify()
          _ => ""
        }
      _ => ""
    }
    if name == "" {
      continue
    }
    out.push({
      index: i,
      id: None,
      name: Some(name),
      arguments: Some(arguments),
    })
  }
  out
}

///|
// Parse one Anthropic Messages API streaming event. The SSE `data:` payload
// carries a `type` field; content blocks use an `index` that maps directly to
// our tool-call fragment index.
pub fn parse_anthropic_chunk(payload : String) -> StreamChunk? {
  let document = @json.parse(payload) catch { _ => return None }
  guard document is Object(fields) else { return None }
  let event_type = match fields.get("type") {
    Some(String(s)) => s
    _ => return None
  }
  let block_index = match fields.get("index") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  if event_type == "content_block_delta" {
    guard fields.get("delta") is Some(Object(d)) else { return None }
    match d.get("type") {
      Some(String(t)) =>
        if t == "text_delta" {
          match d.get("text") {
            Some(String(text)) =>
              Some({
                content: Some(text),
                reasoning_content: None,
                tool_calls: [],
                finish_reason: None,
              })
            _ => None
          }
        } else if t == "input_json_delta" {
          match d.get("partial_json") {
            Some(String(partial)) =>
              Some({
                content: None,
                reasoning_content: None,
                tool_calls: [
                  {
                    index: block_index,
                    id: None,
                    name: None,
                    arguments: Some(partial),
                  },
                ],
                finish_reason: None,
              })
            _ => None
          }
        } else if t == "thinking_delta" {
          match d.get("thinking") {
            Some(String(text)) =>
              Some({
                content: None,
                reasoning_content: Some(text),
                tool_calls: [],
                finish_reason: None,
              })
            _ => None
          }
        } else {
          None
        }
      _ => None
    }
  } else if event_type == "content_block_start" {
    guard fields.get("content_block") is Some(Object(block)) else {
      return None
    }
    match block.get("type") {
      Some(String(bt)) =>
        if bt == "tool_use" {
          let id = match block.get("id") {
            Some(String(s)) => Some(s)
            _ => None
          }
          let name = match block.get("name") {
            Some(String(s)) => Some(s)
            _ => None
          }
          Some({
            content: None,
            reasoning_content: None,
            tool_calls: [{ index: block_index, id, name, arguments: Some("") }],
            finish_reason: None,
          })
        } else {
          None
        }
      _ => None
    }
  } else if event_type == "message_delta" {
    let finish = match fields.get("delta") {
      Some(Object(d)) =>
        match d.get("stop_reason") {
          Some(String(s)) => Some(s)
          _ => None
        }
      _ => None
    }
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [],
      finish_reason: finish,
    })
  } else {
    None
  }
}

///|
// Extract and concatenate system messages (Anthropic sends system as a top
// level parameter instead of a role).
fn anthropic_system(messages : Array[Json]) -> String {
  let b = StringBuilder::new()
  for m in messages {
    if m is Object(fields) {
      let is_system = match fields.get("role") {
        Some(String(r)) => r == "system"
        _ => false
      }
      if is_system {
        match fields.get("content") {
          Some(String(c)) => {
            b.write_string(c)
            b.write_string("\n")
          }
          _ => ()
        }
      }
    }
  }
  b.to_string().trim().to_owned()
}

///|
// Convert OpenAI-style messages to the Anthropic Messages API shape: system
// becomes a top-level parameter, assistant tool calls become content blocks,
// and consecutive tool results are merged into one user message with
// tool_result blocks.
pub fn anthropic_messages(messages : Array[Json]) -> Array[Json] {
  let out : Array[Json] = []
  let mut tool_results : Array[Json] = []
  for m in messages {
    guard m is Object(fields) else { continue }
    let role = match fields.get("role") {
      Some(String(r)) => r
      _ => ""
    }
    if role == "system" {
      continue
    } else if role == "tool" {
      let id = match fields.get("tool_call_id") {
        Some(String(s)) => s
        _ => ""
      }
      let content = match fields.get("content") {
        Some(String(s)) => s
        _ => ""
      }
      tool_results.push(
        Json::object({
          "type": Json::string("tool_result"),
          "tool_use_id": Json::string(id),
          "content": Json::string(content),
        }),
      )
    } else {
      // Flush pending tool results before the next assistant/user turn.
      if tool_results.length() > 0 {
        out.push(
          Json::object({
            "role": Json::string("user"),
            "content": Json::array(tool_results),
          }),
        )
        tool_results = []
      }
      if role == "assistant" {
        let blocks : Array[Json] = []
        match fields.get("content") {
          Some(String(c)) =>
            if c != "" {
              blocks.push(
                Json::object({
                  "type": Json::string("text"),
                  "text": Json::string(c),
                }),
              )
            }
          _ => ()
        }
        match fields.get("tool_calls") {
          Some(Array(calls)) =>
            for call in calls {
              guard call is Object(tc) else { continue }
              let id = match tc.get("id") {
                Some(String(s)) => s
                _ => ""
              }
              let name = match tc.get("function") {
                Some(Object(f)) =>
                  match f.get("name") {
                    Some(String(n)) => n
                    _ => ""
                  }
                _ => ""
              }
              let args = match tc.get("function") {
                Some(Object(f)) =>
                  match f.get("arguments") {
                    Some(String(a)) =>
                      @json.parse(a) catch {
                        _ => Json::object({})
                      }
                    _ => Json::object({})
                  }
                _ => Json::object({})
              }
              blocks.push(
                Json::object({
                  "type": Json::string("tool_use"),
                  "id": Json::string(id),
                  "name": Json::string(name),
                  "input": args,
                }),
              )
            }
          _ => ()
        }
        out.push(
          Json::object({
            "role": Json::string("assistant"),
            "content": Json::array(blocks),
          }),
        )
      } else {
        match fields.get("content") {
          Some(String(c)) =>
            out.push(
              Json::object({
                "role": Json::string("user"),
                "content": Json::string(c),
              }),
            )
          _ => ()
        }
      }
    }
  }
  if tool_results.length() > 0 {
    out.push(
      Json::object({
        "role": Json::string("user"),
        "content": Json::array(tool_results),
      }),
    )
  }
  out
}

///|
// Convert OpenAI-style tool schemas to the Anthropic shape
// (name/description/input_schema).
pub fn anthropic_tools(tools : Array[Json]) -> Array[Json] {
  let out : Array[Json] = []
  for t in tools {
    guard t is Object(fields) else { continue }
    guard fields.get("function") is Some(Object(function)) else { continue }
    let name = match function.get("name") {
      Some(String(n)) => n
      _ => ""
    }
    let description = match function.get("description") {
      Some(String(d)) => d
      _ => ""
    }
    let input_schema = match function.get("parameters") {
      Some(p) => p
      _ =>
        Json::object({
          "type": Json::string("object"),
          "properties": Json::object({}),
        })
    }
    out.push(
      Json::object({
        "name": Json::string(name),
        "description": Json::string(description),
        "input_schema": input_schema,
      }),
    )
  }
  out
}
