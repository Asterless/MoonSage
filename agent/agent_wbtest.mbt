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
