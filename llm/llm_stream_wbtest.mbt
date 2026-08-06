///|
test "parse_sse_line classifies data, done, comments and blanks" {
  assert_eq(parse_sse_line("data: {\"a\":1}"), Data("{\"a\":1}"))
  assert_eq(parse_sse_line("data: [DONE]"), Done)
  assert_eq(parse_sse_line(""), Skip)
  assert_eq(parse_sse_line(": keep-alive comment"), Skip)
  assert_eq(parse_sse_line("event: message"), Skip)
  assert_eq(parse_sse_line("data:{\"a\":1}\r"), Data("{\"a\":1}"))
}

///|
test "parse_stream_chunk extracts deltas and finish reason" {
  let content = parse_stream_chunk(
    "{\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":null}]}",
  )
  assert_eq(
    content,
    Some({ content: Some("Hi"), tool_calls: [], finish_reason: None }),
  )
  let tool = parse_stream_chunk(
    "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"search_modules\",\"arguments\":\"{\\\"query\\\":\\\"http\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}",
  )
  assert_eq(
    tool,
    Some({
      content: None,
      tool_calls: [
        {
          index: 0,
          id: Some("c1"),
          name: Some("search_modules"),
          arguments: Some("{\"query\":\"http\"}"),
        },
      ],
      finish_reason: Some("tool_calls"),
    }),
  )
  assert_eq(parse_stream_chunk("not json"), None)
  assert_eq(
    parse_stream_chunk(
      "{\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}",
    ),
    None,
  )
}

///|
test "tool call accumulator concatenates fragmented arguments" {
  let acc = ToolCallAccumulator::new()
  acc.add([
    {
      index: 0,
      id: Some("call_1"),
      name: Some("search_modules"),
      arguments: Some(""),
    },
  ])
  acc.add([{ index: 0, id: None, name: None, arguments: Some("{\"query\":") }])
  acc.add([{ index: 0, id: None, name: None, arguments: Some("\"http\"}") }])
  let calls = acc.finish()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].id, "call_1")
  assert_eq(calls[0].name, "search_modules")
  assert_eq(calls[0].arguments, "{\"query\":\"http\"}")
}

///|
async fn mock_llm_server(
  group : @async.TaskGroup[Unit],
  responses : Array[String],
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  group.spawn_bg(no_wait=true) <| () => {
    let mut index = 0
    server.run_forever() <| ((_request, body, conn) => {
      while body.read_some() is Some(_) {
        ()
      }
      if index < responses.length() {
        let sse = responses[index]
        index += 1
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        ..write(sse)
        .flush()
      } else {
        conn.send_response(500, "unexpected request")
      }
    })
  }
  server.addr.port()
}

///|
fn sse_chunk(choice : Json) -> String {
  "data: " +
  Json::object({ "choices": Json::array([choice]) }).stringify() +
  "\n"
}

///|
fn content_choice(text : String, finish_reason? : String = "") -> Json {
  let obj : Map[String, Json] = {
    "delta": Json::object({ "content": Json::string(text) }),
  }
  match finish_reason {
    "" => obj["finish_reason"] = Json::null()
    reason => obj["finish_reason"] = Json::string(reason)
  }
  Json::object(obj)
}

///|
fn tool_call_choice(
  index : Int,
  id : String,
  name : String,
  arguments : String,
  finish_reason? : String = "",
) -> Json {
  // Only emit fields that are non-empty: real streaming chunks repeat the
  // `index` but omit `id` / `name` / `arguments` once they were sent.
  let tool_call : Map[String, Json] = {
    "index": Json::number(index.to_double()),
    "type": Json::string("function"),
  }
  if id != "" {
    tool_call["id"] = Json::string(id)
  }
  let function : Map[String, Json] = Map([])
  if name != "" {
    function["name"] = Json::string(name)
  }
  if arguments != "" {
    function["arguments"] = Json::string(arguments)
  }
  tool_call["function"] = Json::object(function)
  let delta : Map[String, Json] = {
    "tool_calls": Json::array([Json::object(tool_call)]),
  }
  let obj : Map[String, Json] = { "delta": Json::object(delta) }
  match finish_reason {
    "" => obj["finish_reason"] = Json::null()
    reason => obj["finish_reason"] = Json::string(reason)
  }
  Json::object(obj)
}

///|
async test "stream_chat_completion receives text deltas incrementally" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(content_choice("Hello")) +
      sse_chunk(content_choice(" world")) +
      sse_chunk(content_choice("", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [sse])
    let deltas = StringBuilder::new()
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
      on_delta=async fn(text) {
        deltas.write_string(text)
        @async.sleep(0)
      },
    )
    assert_eq(result.content, "Hello world")
    assert_eq(deltas.to_string(), "Hello world")
    assert_eq(result.finish_reason, Some("stop"))
    assert_eq(result.tool_calls.length(), 0)
  }
}

///|
async test "stream_chat_completion assembles tool calls from fragments" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(tool_call_choice(0, "call_1", "search_modules", "")) +
      sse_chunk(tool_call_choice(0, "", "", "{\"query\":")) +
      sse_chunk(tool_call_choice(0, "", "", "\"http\"}")) +
      sse_chunk(tool_call_choice(0, "", "", "", finish_reason="tool_calls")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [sse])
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [
        Json::object({
          "type": Json::string("function"),
          "function": Json::object({
            "name": Json::string("search_modules"),
            "description": Json::string("d"),
            "parameters": Json::object({}),
          }),
        }),
      ],
      max_tokens=64,
      on_delta=async fn(_ : String) { @async.sleep(0) },
    )
    assert_eq(result.content, "")
    assert_eq(result.finish_reason, Some("tool_calls"))
    assert_eq(result.tool_calls.length(), 1)
    assert_eq(result.tool_calls[0].id, "call_1")
    assert_eq(result.tool_calls[0].name, "search_modules")
    assert_eq(result.tool_calls[0].arguments, "{\"query\":\"http\"}")
  }
}

///|
// 延迟 delay_ms 后才返回 SSE 响应，模拟 LLM 服务响应缓慢/中断。
async fn mock_llm_server_delayed(
  group : @async.TaskGroup[Unit],
  delay_ms : Int,
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, body, conn) => {
      while body.read_some() is Some(_) {
        ()
      }
      @async.sleep(delay_ms)
      let sse = sse_chunk(content_choice("late", finish_reason="stop")) +
        "data: [DONE]\n"
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "text/event-stream",
      })
      ..write(sse)
      .flush()
    })
  }
  server.addr.port()
}

///|
async test "stream_chat_completion times out when the response is delayed" {
  @async.with_task_group() <| group => {
    let port = mock_llm_server_delayed(group, 500)
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          connect_timeout_ms=100,
        ),
      )
      false
    } catch {
      e => e.to_string().contains("timed out")
    }
    assert_true(raised)
  }
}

///|
