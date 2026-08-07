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
fn reasoning_choice(text : String) -> Json {
  let obj : Map[String, Json] = {
    "delta": Json::object({ "reasoning_content": Json::string(text) }),
  }
  obj["finish_reason"] = Json::null()
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
async test "run_llm_agent executes tool calls then returns a streamed answer" {
  @async.with_task_group() <| group => {
    let round1 = sse_chunk(tool_call_choice(0, "call_1", "search_modules", "")) +
      sse_chunk(tool_call_choice(0, "", "", "{\"query\":\"http\"}")) +
      sse_chunk(tool_call_choice(0, "", "", "", finish_reason="tool_calls")) +
      "data: [DONE]\n"
    let round2 = sse_chunk(content_choice("Found ")) +
      sse_chunk(content_choice("it", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [round1, round2])
    let modules : Array[@moonsage.ModuleSummary] = [
      {
        name: "owner/http-client",
        version: "1.0.0",
        license: "MIT",
        repository: "",
        keywords: ["http"],
        description: "A native HTTP client",
        created_at: "",
      },
    ]
    let answer = run_llm_agent(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      modules,
      "find http client",
    )
    assert_eq(answer.text, "Found it")
    assert_true(answer.trace.contains("[tool] search_modules"))
    assert_true(answer.trace.contains("[final] Model returned an answer"))
  }
}

///|
async test "Agent::turn forwards reasoning_content to on_thinking" {
  @async.with_task_group() <| group => {
    let round1 = sse_chunk(reasoning_choice("thinking step 1")) +
      sse_chunk(tool_call_choice(0, "call_1", "search_modules", "")) +
      sse_chunk(tool_call_choice(0, "", "", "{\"query\":\"http\"}")) +
      sse_chunk(tool_call_choice(0, "", "", "", finish_reason="tool_calls")) +
      "data: [DONE]\n"
    let round2 = sse_chunk(content_choice("done", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [round1, round2])
    let agent = ask_agent([])
    let session = agent.new_session()
    let thinking = StringBuilder::new()
    let answer = agent.turn(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      "find http client",
      on_thinking=async fn(text) {
        thinking.write_string(text)
        @async.sleep(0)
      },
    )
    assert_eq(answer.text, "done")
    assert_true(thinking.to_string().contains("thinking step 1"))
  }
}

///|
test "ask_agent exposes the four research tools with ask budget" {
  let agent = ask_agent([])
  let names = agent.tools.map(fn(t) { t.schema.name })
  assert_eq(names, [
    "search_modules", "get_module_manifest", "get_module_index", "get_package_docs",
  ])
  assert_true(!names.contains("write_file"))
  assert_eq(agent.max_tool_calls, 12)
  assert_eq(agent.max_rounds, 6)
  assert_true(agent.max_tokens > 0)
}

///|
async test "Agent::turn carries conversation history across turns" {
  @async.with_task_group() <| group => {
    let round1 = sse_chunk(content_choice("first", finish_reason="stop")) +
      "data: [DONE]\n"
    let round2 = sse_chunk(content_choice("second", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [round1, round2])
    let agent : Agent = {
      system_prompt: "you are a test assistant",
      tools: [],
      max_tool_calls: 5,
      max_rounds: 3,
      max_tokens: 64,
    }
    let session = agent.new_session()
    let first = agent.turn(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      "hello",
    )
    assert_eq(first.text, "first")
    // 回合 1 结束后，会话应包含 system、user、assistant 三条消息。
    assert_eq(session.messages.length(), 3)
    assert_true(session.messages[2].stringify().contains("first"))
    let second = agent.turn(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      "follow up",
    )
    assert_eq(second.text, "second")
    // 回合 2 结束后继续追加 user + assistant 两条消息。
    assert_eq(session.messages.length(), 5)
    assert_true(session.messages[4].stringify().contains("second"))
  }
}

///|
async test "Agent::turn emits tool and answer events" {
  @async.with_task_group() <| group => {
    let round1 = sse_chunk(tool_call_choice(0, "call_1", "search_modules", "")) +
      sse_chunk(tool_call_choice(0, "", "", "{\"query\":\"http\"}")) +
      sse_chunk(tool_call_choice(0, "", "", "", finish_reason="tool_calls")) +
      "data: [DONE]\n"
    let round2 = sse_chunk(content_choice("Found it", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [round1, round2])
    let modules : Array[@moonsage.ModuleSummary] = [
      {
        name: "owner/http-client",
        version: "1.0.0",
        license: "MIT",
        repository: "",
        keywords: ["http"],
        description: "A native HTTP client",
        created_at: "",
      },
    ]
    let events : Array[EngineEvent] = []
    let answer = run_llm_agent(
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      modules,
      "find http client",
      on_event=async fn(ev) {
        events.push(ev)
        @async.sleep(0)
      },
    )
    assert_eq(answer.text, "Found it")
    assert_eq(events.length(), 3)
    assert_true(events[0] is ToolCall("search_modules"))
    assert_true(events[1] is ToolResult("search_modules"))
    assert_true(events[2] is AnswerDelta("Found it"))
  }
}

///|
async test "Agent::compact summarizes old history" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(content_choice("摘要内容", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [sse])
    let agent : Agent = {
      system_prompt: "sys",
      tools: [],
      max_tool_calls: 5,
      max_rounds: 3,
      max_tokens: 64,
    }
    let session = agent.new_session()
    for i = 0; i < 10; i = i + 1 {
      session.messages.push(
        @llm.chat_message("user", "message " + i.to_string()),
      )
      session.messages.push(
        @llm.chat_message("assistant", "answer " + i.to_string()),
      )
    }
    let before = session.messages.length()
    agent.compact(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      threshold_tokens=1,
    )
    assert_true(session.messages.length() < before)
    // system + 摘要 + 最近 2 轮(4 条)= 6 条
    assert_eq(session.messages.length(), 6)
    assert_true(session.messages[1].stringify().contains("摘要内容"))
  }
}

///|
async test "budget-exhausted final answer continues when truncated" {
  @async.with_task_group() <| group => {
    let round1 = sse_chunk(
        content_choice("部分内容", finish_reason="length"),
      ) +
      "data: [DONE]\n"
    let round2 = sse_chunk(content_choice("续写内容", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [round1, round2])
    let agent : Agent = {
      system_prompt: "sys",
      tools: [],
      max_tool_calls: 0,
      max_rounds: 1,
      max_tokens: 64,
    }
    let session = agent.new_session()
    let answer = agent.turn(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      "hi",
    )
    assert_eq(answer.text, "部分内容\n续写内容")
    assert_true(
      answer.trace.contains(
        "[final] Model answered from collected evidence (continued)",
      ),
    )
  }
}

///|
async test "compact keeps tool results with their tool_calls message" {
  @async.with_task_group() <| group => {
    let sse = sse_chunk(content_choice("摘要", finish_reason="stop")) +
      "data: [DONE]\n"
    let port = mock_llm_server(group, [sse])
    let agent : Agent = {
      system_prompt: "sys",
      tools: [],
      max_tool_calls: 5,
      max_rounds: 3,
      max_tokens: 64,
    }
    let session = agent.new_session()
    for i = 0; i < 8; i = i + 1 {
      session.messages.push(@llm.chat_message("user", "u" + i.to_string()))
      session.messages.push(@llm.chat_message("assistant", "a" + i.to_string()))
    }
    // 结尾：assistant(tool_calls) + tool 结果 + user + assistant
    let tool_call : @llm.ChatToolCall = { id: "c1", name: "t", arguments: "{}" }
    session.messages.push(
      @llm.assistant_message_with_tool_calls("", [tool_call]),
    )
    session.messages.push(@llm.tool_result_message("c1", "ok"))
    session.messages.push(@llm.chat_message("user", "继续"))
    session.messages.push(@llm.chat_message("assistant", "完成"))
    agent.compact(
      session,
      "test-key",
      "http://127.0.0.1:\{port}",
      "test-model",
      threshold_tokens=1,
    )
    // 校验：任何 tool 消息前一条必须是带 tool_calls 的 assistant。
    for i = 1; i < session.messages.length(); i = i + 1 {
      if message_role(session.messages[i]) == "tool" {
        assert_true(is_assistant_with_tool_calls(session.messages[i - 1]))
      }
    }
  }
}

///|
fn is_assistant_with_tool_calls(message : Json) -> Bool {
  match message {
    Object(fields) =>
      fields.get("role") is Some(String("assistant")) &&
      fields.get("tool_calls") is Some(Array(_))
    _ => false
  }
}
