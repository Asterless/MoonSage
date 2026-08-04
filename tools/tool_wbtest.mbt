///|
test "error_json wraps messages in a JSON object" {
  assert_eq(error_json("boom"), "{\"error\":\"boom\"}")
  assert_eq(error_json(""), "{\"error\":\"\"}")
}

///|
test "argument_string extracts required arguments" {
  let ok = argument_string("{\"query\":\"http\"}", "query") catch { _ => "" }
  assert_eq(ok, "http")
  // empty value is still returned
  let empty = argument_string("{\"query\":\"\"}", "query") catch { _ => "x" }
  assert_eq(empty, "")
  let raised = try {
    ignore(argument_string("{}", "query"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  let non_string = try {
    ignore(argument_string("{\"query\":1}", "query"))
    false
  } catch {
    _ => true
  }
  assert_true(non_string)
  let malformed = try {
    ignore(argument_string("not json", "query"))
    false
  } catch {
    _ => true
  }
  assert_true(malformed)
}

///|
fn sample_tool(name : String) -> Tool {
  {
    schema: { name, description: "d", parameters: Json::object({}) },
    execute: async fn(arguments : String) {
      let out = arguments
      @async.sleep(0)
      out
    },
  }
}

///|
test "find_tool locates tools by name" {
  let tools = [sample_tool("a"), sample_tool("b")]
  match find_tool(tools, "b") {
    Some(t) => assert_eq(t.schema.name, "b")
    None => assert_true(false)
  }
  assert_true(find_tool(tools, "missing") is None)
  assert_true(find_tool([], "a") is None)
}

///|
async test "Tool::run invokes the execute closure" {
  let tool = sample_tool("echo")
  let out = tool.run("{\"x\":1}")
  assert_eq(out, "{\"x\":1}")
}
