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
    Some({
      content: Some("Hi"),
      reasoning_content: None,
      tool_calls: [],
      finish_reason: None,
    }),
  )
  let tool = parse_stream_chunk(
    "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"search_modules\",\"arguments\":\"{\\\"query\\\":\\\"http\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}",
  )
  assert_eq(
    tool,
    Some({
      content: None,
      reasoning_content: None,
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
test "parse_stream_chunk extracts reasoning_content" {
  let chunk = parse_stream_chunk(
    "{\"choices\":[{\"delta\":{\"reasoning_content\":\"think hard\"},\"finish_reason\":null}]}",
  )
  assert_eq(
    chunk,
    Some({
      content: None,
      reasoning_content: Some("think hard"),
      tool_calls: [],
      finish_reason: None,
    }),
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
async test "stream_chat_completion assembles and streams reasoning_content" {
  @async.with_task_group() <| group => {
    let reasoning_chunk = "data: " +
      Json::object({
        "choices": Json::array([
          Json::object({
            "delta": Json::object({
              "reasoning_content": Json::string("let me think"),
            }),
            "finish_reason": Json::null(),
          }),
        ]),
      }).stringify() +
      "\n"
    let sse = reasoning_chunk +
      sse_chunk(content_choice("answer", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [sse])
    let reasoning = StringBuilder::new()
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
      on_reasoning=async fn(text) {
        reasoning.write_string(text)
        @async.sleep(0)
      },
    )
    assert_eq(result.content, "answer")
    assert_eq(result.reasoning_content, "let me think")
    assert_eq(reasoning.to_string(), "let me think")
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
async test "stream_chat_completion rejects EOF after a content delta" {
  @async.with_task_group() <| group => {
    let port = mock_llm_server(group, [
      sse_chunk(content_choice("partial answer")),
    ])
    let deltas = StringBuilder::new()
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          max_retries=0,
          on_delta=async fn(text) {
            deltas.write_string(text)
            @async.sleep(0)
          },
        ),
      )
      false
    } catch {
      e => e.to_string().contains("stream closed before completion")
    }
    assert_true(raised)
    assert_eq(deltas.to_string(), "partial answer")
  }
}

///|
async test "stream_chat_completion rejects EOF during tool arguments" {
  @async.with_task_group() <| group => {
    let partial = sse_chunk(
      tool_call_choice(0, "call_1", "search_modules", "{\"query\":"),
    )
    let port = mock_llm_server(group, [partial])
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          max_retries=0,
        ),
      )
      false
    } catch {
      e => e.to_string().contains("stream closed before completion")
    }
    assert_true(raised)
  }
}

///|
async test "stream retry suppresses an already emitted prefix" {
  @async.with_task_group() <| group => {
    let interrupted = sse_chunk(content_choice("Hello"))
    let complete = sse_chunk(content_choice("Hello")) +
      sse_chunk(content_choice(" world")) +
      sse_chunk(content_choice("", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [interrupted, complete])
    let deltas = StringBuilder::new()
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
      max_retries=1,
      retry_delay_ms=10,
      on_delta=async fn(text) {
        deltas.write_string(text)
        @async.sleep(0)
      },
    )
    assert_eq(result.content, "Hello world")
    assert_eq(deltas.to_string(), "Hello world")
    assert_eq(result.finish_reason, Some("stop"))
  }
}

///|
async test "stream retry rejects a shorter completed response" {
  @async.with_task_group() <| group => {
    let interrupted = sse_chunk(content_choice("Hello world"))
    let shorter = sse_chunk(content_choice("Hello")) +
      sse_chunk(content_choice("", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [interrupted, shorter])
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          max_retries=1,
          retry_delay_ms=10,
        ),
      )
      false
    } catch {
      e =>
        e
        .to_string()
        .contains("retry ended before reproducing the partial response")
    }
    assert_true(raised)
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
// 前 statuses.length() 次请求返回指定 HTTP 码,之后返回正常 SSE;
// 通过共享计数器暴露实际接收到的请求数,便于断言重试次数。
async fn mock_llm_server_with_status(
  group : @async.TaskGroup[Unit],
  statuses : Array[Int],
  ok_sse : String,
  received : Array[Int],
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  group.spawn_bg(no_wait=true) <| () => {
    let mut index = 0
    server.run_forever() <| ((_request, body, conn) => {
      while body.read_some() is Some(_) {
        ()
      }
      received[0] = received[0] + 1
      if index < statuses.length() {
        let code = statuses[index]
        index += 1
        conn.send_response(code, "transient error")
      } else {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        ..write(ok_sse)
        .flush()
      }
    })
  }
  server.addr.port()
}

///|
async test "stream_chat_completion retries a 500 then recovers" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(content_choice("recovered", finish_reason="stop")) +
      "data: [DONE]\n"
    let received : Array[Int] = [0]
    let port = mock_llm_server_with_status(group, [500], sse, received)
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
      max_retries=2,
      retry_delay_ms=50,
    )
    assert_eq(result.content, "recovered")
    assert_eq(received[0], 2)
  }
}

///|
async test "stream_chat_completion retries a 429 then recovers" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(content_choice("ok", finish_reason="stop")) +
      "data: [DONE]\n"
    let received : Array[Int] = [0]
    let port = mock_llm_server_with_status(group, [429], sse, received)
    let result = stream_chat_completion(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
      max_retries=2,
      retry_delay_ms=50,
    )
    assert_eq(result.content, "ok")
    assert_eq(received[0], 2)
  }
}

///|
async test "stream_chat_completion does not retry a 400" {
  @async.with_task_group() <| group => {
    let received : Array[Int] = [0]
    let port = mock_llm_server_with_status(group, [400], "", received)
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          max_retries=2,
          retry_delay_ms=50,
        ),
      )
      false
    } catch {
      e => e.to_string().contains("HTTP 400")
    }
    assert_true(raised)
    assert_eq(received[0], 1)
  }
}

///|
async test "stream_chat_completion strips retry marker after retries are spent" {
  @async.with_task_group() <| group => {
    let received : Array[Int] = [0]
    let port = mock_llm_server_with_status(group, [503, 503, 503], "", received)
    let raised = try {
      ignore(
        stream_chat_completion(
          "test-key",
          "http://127.0.0.1:\{port}",
          "test-model",
          [chat_message("user", "hi")],
          [],
          max_tokens=64,
          max_retries=2,
          retry_delay_ms=50,
        ),
      )
      false
    } catch {
      e => {
        let message = e.to_string()
        message.contains("HTTP 503") && !message.contains("retryable:")
      }
    }
    assert_true(raised)
    assert_eq(received[0], 3)
  }
}

///|
test "parse_ollama_chunk extracts content, tool calls and done" {
  let text = parse_ollama_chunk(
    "{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"done\":false}",
  )
  assert_eq(
    text,
    Some({
      content: Some("hi"),
      reasoning_content: None,
      tool_calls: [],
      finish_reason: None,
    }),
  )
  let tool = parse_ollama_chunk(
    "{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"name\":\"search\",\"arguments\":{\"q\":\"x\"}}}]},\"done\":false}",
  )
  assert_eq(
    tool,
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [
        {
          index: 0,
          id: None,
          name: Some("search"),
          arguments: Some("{\"q\":\"x\"}"),
        },
      ],
      finish_reason: None,
    }),
  )
  let done = parse_ollama_chunk("{\"done\":true,\"done_reason\":\"stop\"}")
  assert_eq(
    done,
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [],
      finish_reason: Some("stop"),
    }),
  )
  assert_eq(parse_ollama_chunk("not json"), None)
}

///|
test "parse_anthropic_chunk handles text, thinking, tool use and stop" {
  let text = parse_anthropic_chunk(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
  )
  assert_eq(
    text,
    Some({
      content: Some("Hi"),
      reasoning_content: None,
      tool_calls: [],
      finish_reason: None,
    }),
  )
  let thinking = parse_anthropic_chunk(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"ponder\"}}",
  )
  assert_eq(
    thinking,
    Some({
      content: None,
      reasoning_content: Some("ponder"),
      tool_calls: [],
      finish_reason: None,
    }),
  )
  let start = parse_anthropic_chunk(
    "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"search\",\"input\":{}}}",
  )
  assert_eq(
    start,
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [
        {
          index: 2,
          id: Some("toolu_1"),
          name: Some("search"),
          arguments: Some(""),
        },
      ],
      finish_reason: None,
    }),
  )
  let json_delta = parse_anthropic_chunk(
    "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":\\\"x\\\"}\"}}",
  )
  assert_eq(
    json_delta,
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [
        { index: 2, id: None, name: None, arguments: Some("{\"q\":\"x\"}") },
      ],
      finish_reason: None,
    }),
  )
  let stop = parse_anthropic_chunk(
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
  )
  assert_eq(
    stop,
    Some({
      content: None,
      reasoning_content: None,
      tool_calls: [],
      finish_reason: Some("end_turn"),
    }),
  )
  assert_eq(
    parse_anthropic_chunk(
      "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\"}}",
    ),
    None,
  )
}

///|
test "anthropic message conversion splits system and merges tool results" {
  let messages = [
    chat_message("system", "You are helpful"),
    chat_message("user", "hi"),
    assistant_message_with_tool_calls("", [
      { id: "c1", name: "search", arguments: "{\"q\":\"x\"}" },
    ]),
    tool_result_message("c1", "ok"),
    chat_message("user", "thanks"),
  ]
  assert_eq(anthropic_system(messages), "You are helpful")
  let converted = anthropic_messages(messages)
  assert_eq(converted.length(), 4)
  // user "hi"
  assert_eq(converted[0].stringify(), "{\"role\":\"user\",\"content\":\"hi\"}")
  // assistant with text + tool_use blocks
  assert_true(converted[1].stringify().contains("\"type\":\"tool_use\""))
  assert_true(converted[1].stringify().contains("\"id\":\"c1\""))
  assert_true(converted[1].stringify().contains("\"input\":{\"q\":\"x\"}"))
  // merged tool_result user message
  assert_eq(
    converted[2].stringify(),
    "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"c1\",\"content\":\"ok\"}]}",
  )
  // trailing plain user message is preserved after the merged tool results
  assert_eq(
    converted[3].stringify(),
    "{\"role\":\"user\",\"content\":\"thanks\"}",
  )
}

///|
test "anthropic tools convert OpenAI schema to input_schema" {
  let tools = [
    Json::object({
      "type": Json::string("function"),
      "function": Json::object({
        "name": Json::string("search"),
        "description": Json::string("Find things"),
        "parameters": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({}),
        }),
      }),
    }),
  ]
  let converted = anthropic_tools(tools)
  assert_eq(converted.length(), 1)
  assert_true(converted[0].stringify().contains("\"name\":\"search\""))
  assert_true(
    converted[0].stringify().contains("\"input_schema\":{\"type\":\"object\""),
  )
}

///|
async test "stream_chat_completion_provider speaks the Anthropic protocol" {
  @async.with_task_group() <| group => {
    let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n" +
      "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\n" +
      "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n"
    let port = mock_llm_server(group, [sse])
    let deltas = StringBuilder::new()
    let result = stream_chat_completion_provider(
      Anthropic,
      "test-key",
      "http://127.0.0.1:\{port}",
      "claude-test",
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
    assert_eq(result.finish_reason, Some("end_turn"))
  }
}

///|
async test "stream_chat_completion_provider speaks the Ollama protocol" {
  @async.with_task_group() <| group => {
    let sse = "data: {\"message\":{\"role\":\"assistant\",\"content\":\"O\"},\"done\":false}\n" +
      "data: {\"message\":{\"role\":\"assistant\",\"content\":\"K\"},\"done\":false}\n" +
      "data: {\"done\":true,\"done_reason\":\"stop\"}\n"
    let port = mock_llm_server(group, [sse])
    let result = stream_chat_completion_provider(
      Ollama,
      "",
      "http://127.0.0.1:\{port}",
      "llama-test",
      [chat_message("user", "hi")],
      [],
      max_tokens=64,
    )
    assert_eq(result.content, "OK")
    assert_eq(result.finish_reason, Some("stop"))
  }
}
