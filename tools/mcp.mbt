///|
/// Configuration for one stdio Model Context Protocol server. The command is
/// intentionally explicit: running an MCP server grants it the same local
/// process permissions as MoonSage.
pub(all) struct McpServerConfig {
  name : String
  command : String
  args : Array[String]
  timeout_ms : Int
} derive(Eq, Debug)

///|
fn json_string_field(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) if value != "" => Some(value)
    _ => None
  }
}

///|
fn json_string_array(fields : Map[String, Json], key : String) -> Array[String] {
  match fields.get(key) {
    Some(Array(values)) =>
      values.filter_map(fn(value) {
        match value {
          String(text) => Some(text)
          _ => None
        }
      })
    _ => []
  }
}

///|
/// Parse a single server configuration from JSON. The expected shape is
/// `{ "name": "server", "command": "program", "args": ["..."],
/// "timeout_ms": 30000 }`.
pub fn McpServerConfig::from_json(document : Json) -> McpServerConfig? {
  guard document is Object(fields) else { return None }
  guard json_string_field(fields, "name") is Some(name) else { return None }
  guard json_string_field(fields, "command") is Some(command) else {
    return None
  }
  let timeout_ms = match fields.get("timeout_ms") {
    Some(Number(value, ..)) if value > 0.0 => value.to_int()
    _ => 30_000
  }
  Some({ name, command, args: json_string_array(fields, "args"), timeout_ms })
}

///|
fn json_rpc_request(id : Int, rpc_method : String, params : Json?) -> Json {
  let fields : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(id.to_double()),
    "method": Json::string(rpc_method),
  }
  match params {
    Some(value) => fields["params"] = value
    None => ()
  }
  Json::object(fields)
}

///|
fn json_rpc_notification(rpc_method : String, params : Json?) -> Json {
  let fields : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(rpc_method),
  }
  match params {
    Some(value) => fields["params"] = value
    None => ()
  }
  Json::object(fields)
}

///|
async fn mcp_read_json_line(
  reader : @process.ReadFromProcess,
  timeout_ms : Int,
) -> Json {
  let next = @async.with_timeout_opt(timeout_ms, async fn() {
    reader.read_until("\n")
  })
  match next {
    None => fail("MCP server timed out after \{timeout_ms} ms")
    Some(None) => fail("MCP server closed stdout before replying")
    Some(Some(line)) => @json.parse(line)
  }
}

///|
fn json_rpc_response_id(document : Json) -> Int? {
  match document {
    Object(fields) =>
      match fields.get("id") {
        Some(Number(value, ..)) => Some(value.to_int())
        _ => None
      }
    _ => None
  }
}

///|
async fn mcp_read_response(
  reader : @process.ReadFromProcess,
  id : Int,
  timeout_ms : Int,
) -> Json {
  let mut count = 0
  while count < 32 {
    let document = mcp_read_json_line(reader, timeout_ms)
    if json_rpc_response_id(document) == Some(id) {
      return document
    }
    count += 1
  }
  fail("MCP server sent too many notifications without replying")
}

///|
fn mcp_result(document : Json, rpc_method : String) -> Json raise {
  guard document is Object(fields) else {
    fail("MCP \{rpc_method} returned a non-object JSON-RPC message")
  }
  match fields.get("error") {
    Some(error) => fail("MCP \{rpc_method} failed: \{error.stringify()}")
    None => ()
  }
  guard fields.get("result") is Some(result) else {
    fail("MCP \{rpc_method} response has no result")
  }
  result
}

///|
/// Run one complete MCP stdio session. Starting a fresh process for each
/// request bounds lifetime and ensures a timed-out server cannot survive a
/// tool call. It also makes each call independent of stale server state.
async fn mcp_request(
  config : McpServerConfig,
  rpc_method : String,
  params : Json,
) -> Json {
  @async.with_task_group() <| group => {
    let (server_input, writer) = @process.write_to_process()
    let (reader, server_output) = @process.read_from_process()
    let process = @process.spawn(
      group,
      config.command,
      config.args,
      stdin=server_input,
      stdout=server_output,
      stderr=@stdio.stderr,
      no_console_window=true,
    )
    defer process.cancel()
    defer writer.close()
    defer reader.close()
    writer.write(
      json_rpc_request(
        1,
        "initialize",
        Some(
          Json::object({
            "protocolVersion": Json::string("2024-11-05"),
            "capabilities": Json::object({}),
            "clientInfo": Json::object({
              "name": Json::string("MoonSage"),
              "version": Json::string("0.1.0"),
            }),
          }),
        ),
      ).stringify() +
      "\n",
    )
    ignore(
      mcp_result(mcp_read_response(reader, 1, config.timeout_ms), "initialize"),
    )
    writer.write(
      json_rpc_notification("notifications/initialized", None).stringify() +
      "\n",
    )
    writer.write(
      json_rpc_request(2, rpc_method, Some(params)).stringify() + "\n",
    )
    mcp_result(mcp_read_response(reader, 2, config.timeout_ms), rpc_method)
  }
}

///|
fn valid_mcp_tool_name(name : String) -> Bool {
  if name == "" || name.length() > 48 {
    return false
  }
  for char in name {
    let code = char.to_int()
    let valid = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      char == '_' ||
      char == '-'
    if !valid {
      return false
    }
  }
  true
}

///|
let max_exposed_mcp_tool_name_length = 64

///|
fn mcp_tool_schema(server_name : String, document : Json) -> ToolSchema? {
  guard document is Object(fields) else { return None }
  guard json_string_field(fields, "name") is Some(name) else { return None }
  guard valid_mcp_tool_name(name) && valid_mcp_tool_name(server_name) else {
    return None
  }
  let exposed_name = "mcp_\{server_name}_\{name}"
  guard exposed_name.length() <= max_exposed_mcp_tool_name_length else {
    return None
  }
  let description = match fields.get("description") {
    Some(String(value)) if value != "" => value
    _ => "MCP tool \{name} from server \{server_name}."
  }
  let parameters = match fields.get("inputSchema") {
    Some(value) if value is Object(_) => value
    _ =>
      Json::object({
        "type": Json::string("object"),
        "properties": Json::object({}),
      })
  }
  Some({
    name: exposed_name,
    description: "[MCP \{server_name}] \{description}",
    parameters,
  })
}

///|
/// Discover `tools/list` from an MCP server and adapt each entry to the
/// ordinary MoonSage tool registry. Names are prefixed with `mcp_<server>_`
/// to avoid collisions with built-in tools.
pub async fn mcp_tools(config : McpServerConfig) -> Array[Tool] {
  let listed = mcp_request(config, "tools/list", Json::object({}))
  guard listed is Object(fields) else {
    fail("MCP tools/list result is not an object")
  }
  guard fields.get("tools") is Some(Array(items)) else {
    fail("MCP tools/list result has no tools array")
  }
  let tools : Array[Tool] = []
  for document in items {
    guard mcp_tool_schema(config.name, document) is Some(schema) else {
      continue
    }
    guard document is Object(fields) else { continue }
    guard json_string_field(fields, "name") is Some(mcp_name) else { continue }
    tools.push({
      schema,
      execute: async fn(arguments) {
        let parsed = @json.parse(arguments) catch {
          _ => return error_json("MCP tool arguments must be JSON")
        }
        let result = mcp_request(
          config,
          "tools/call",
          Json::object({ "name": Json::string(mcp_name), "arguments": parsed }),
        ) catch {
          error => return error_json(error.to_string())
        }
        result.stringify()
      },
    })
  }
  tools
}
