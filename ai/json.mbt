///|
fn required_string(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(value)) else {
    fail("chat JSON field '\{key}' must be a string")
  }
  value
}

///|
fn content_string(fields : Map[String, Json]) -> String raise {
  match fields.get("content") {
    Some(String(value)) => value
    Some(Null) | None => ""
    _ => fail("chat JSON field 'content' must be a string or null")
  }
}

///|
fn tool_call_from_json(document : Json) -> ModelToolCall raise {
  guard document is Object(fields) else {
    fail("tool call must be a JSON object")
  }
  let id = required_string(fields, "id")
  guard fields.get("function") is Some(Object(function)) else {
    fail("tool call field 'function' must be a JSON object")
  }
  {
    id,
    name: required_string(function, "name"),
    arguments: required_string(function, "arguments"),
  }
}

///|
fn ModelToolCall::to_json(self : ModelToolCall) -> Json {
  Json::object({
    "id": Json::string(self.id),
    "type": Json::string("function"),
    "function": Json::object({
      "name": Json::string(self.name),
      "arguments": Json::string(self.arguments),
    }),
  })
}

///|
/// Decode one message from the existing OpenAI-style session representation.
pub fn ChatMessage::from_json(document : Json) -> ChatMessage raise {
  guard document is Object(fields) else {
    fail("chat message must be a JSON object")
  }
  match required_string(fields, "role") {
    "system" => System(content_string(fields))
    "user" => User(content_string(fields))
    "assistant" => {
      let calls : Array[ModelToolCall] = match fields.get("tool_calls") {
        Some(Array(items)) => items.map(tool_call_from_json)
        None | Some(Null) => []
        _ => fail("assistant field 'tool_calls' must be a JSON array")
      }
      Assistant(content=content_string(fields), tool_calls=calls)
    }
    "tool" =>
      Tool(
        tool_call_id=required_string(fields, "tool_call_id"),
        content=content_string(fields),
      )
    role => fail("unsupported chat message role: \{role}")
  }
}

///|
/// Encode one typed message in the existing session representation.
pub fn ChatMessage::to_json(self : ChatMessage) -> Json {
  match self {
    System(content) =>
      Json::object({
        "role": Json::string("system"),
        "content": Json::string(content),
      })
    User(content) =>
      Json::object({
        "role": Json::string("user"),
        "content": Json::string(content),
      })
    Assistant(content~, tool_calls~) => {
      let fields : Map[String, Json] = {
        "role": Json::string("assistant"),
        "content": Json::string(content),
      }
      if !tool_calls.is_empty() {
        fields["tool_calls"] = Json::array(
          tool_calls.map(ModelToolCall::to_json),
        )
      }
      Json::object(fields)
    }
    Tool(tool_call_id~, content~) =>
      Json::object({
        "role": Json::string("tool"),
        "tool_call_id": Json::string(tool_call_id),
        "content": Json::string(content),
      })
  }
}

///|
/// Decode an existing session message array into typed messages.
pub fn messages_from_json(messages : Array[Json]) -> Array[ChatMessage] raise {
  messages.map(ChatMessage::from_json)
}

///|
/// Encode typed messages into the array stored by existing session files.
pub fn messages_to_json(messages : Array[ChatMessage]) -> Array[Json] {
  messages.map(ChatMessage::to_json)
}

///|
/// Decode the complete JSON array stored by an existing session file.
pub fn messages_from_session_json(document : Json) -> Array[ChatMessage] raise {
  guard document is Array(messages) else {
    fail("session document must be a JSON array")
  }
  messages_from_json(messages)
}

///|
/// Encode typed messages as the complete JSON array used by session files.
pub fn messages_to_session_json(messages : Array[ChatMessage]) -> Json {
  Json::array(messages_to_json(messages))
}

///|
/// Decode an OpenAI-style function tool schema.
pub fn ModelTool::from_json(document : Json) -> ModelTool raise {
  guard document is Object(fields) else {
    fail("model tool must be a JSON object")
  }
  guard fields.get("function") is Some(Object(function)) else {
    fail("model tool field 'function' must be a JSON object")
  }
  {
    name: required_string(function, "name"),
    description: required_string(function, "description"),
    parameters: match function.get("parameters") {
      Some(parameters) => parameters
      None => Json::object({})
    },
  }
}

///|
/// Encode a provider-neutral tool as an OpenAI-style function tool schema.
pub fn ModelTool::to_json(self : ModelTool) -> Json {
  Json::object({
    "type": Json::string("function"),
    "function": Json::object({
      "name": Json::string(self.name),
      "description": Json::string(self.description),
      "parameters": self.parameters,
    }),
  })
}

///|
pub fn tools_from_json(tools : Array[Json]) -> Array[ModelTool] raise {
  tools.map(ModelTool::from_json)
}

///|
pub fn tools_to_json(tools : Array[ModelTool]) -> Array[Json] {
  tools.map(ModelTool::to_json)
}
