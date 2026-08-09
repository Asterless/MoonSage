///|
test "McpServerConfig parses a valid stdio configuration" {
  let config = McpServerConfig::from_json(
    Json::object({
      "name": Json::string("files"),
      "command": Json::string("node"),
      "args": Json::array([Json::string("server.js")]),
      "timeout_ms": Json::number(1234.0),
    }),
  )
  assert_eq(
    config,
    Some({
      name: "files",
      command: "node",
      args: ["server.js"],
      timeout_ms: 1234,
    }),
  )
}

///|
test "McpServerConfig rejects malformed configurations" {
  assert_eq(McpServerConfig::from_json(Json::object({})), None)
  assert_eq(
    McpServerConfig::from_json(Json::object({ "name": Json::string("server") })),
    None,
  )
}

///|
test "MCP tool schemas are namespaced and preserve input schema" {
  let schema = mcp_tool_schema(
    "files",
    Json::object({
      "name": Json::string("read_file"),
      "description": Json::string("Read a file"),
      "inputSchema": Json::object({
        "type": Json::string("object"),
        "properties": Json::object({ "path": Json::object({}) }),
      }),
    }),
  )
  guard schema is Some(schema) else {
    assert_true(false)
    return
  }
  assert_eq(schema.name, "mcp_files_read_file")
  assert_eq(schema.description, "[MCP files] Read a file")
  assert_true(schema.parameters.stringify().contains("path"))
}

///|
test "MCP tool schemas reject unsafe names" {
  let bad_server = mcp_tool_schema(
    "../files",
    Json::object({ "name": Json::string("read") }),
  )
  let bad_tool = mcp_tool_schema(
    "files",
    Json::object({ "name": Json::string("read/file") }),
  )
  assert_true(bad_server is None)
  assert_true(bad_tool is None)
}

///|
test "MCP tool schemas reject names exceeding the exposed limit" {
  let schema = mcp_tool_schema(
    "s".repeat(48),
    Json::object({ "name": Json::string("t".repeat(48)) }),
  )
  assert_true(schema is None)
}

///|
test "MCP JSON-RPC requests use the standard envelope" {
  assert_eq(
    json_rpc_request(7, "tools/list", Some(Json::object({}))).stringify(),
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{}}",
  )
  assert_eq(
    json_rpc_notification("notifications/initialized", None).stringify(),
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
}
