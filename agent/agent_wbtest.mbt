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
      threshold_chars=1,
    )
    assert_true(session.messages.length() < before)
    // system + 摘要 + 最近 3 条 = 5 条
    assert_eq(session.messages.length(), 5)
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
