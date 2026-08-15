///|
fn response(
  content : String,
  tool_calls? : Array[@model.ModelToolCall] = [],
  finish_reason? : @model.FinishReason = Stop,
  reasoning? : String = "",
) -> @model.ChatResponse {
  { content, reasoning, tool_calls, finish_reason }
}

///|
fn queued_client(
  responses : Array[@model.ChatResponse],
  streamed : Array[Array[@model.ModelEvent]],
  requests : Array[@model.ChatRequest],
) -> @model.ChatClient {
  let next = [0]
  @model.ChatClient::new(async fn(request, on_event) {
    let index = next[0]
    next[0] += 1
    requests.push(request)
    if index < streamed.length() {
      for event in streamed[index] {
        on_event(event)
      }
    }
    guard responses.get(index) is Some(result) else {
      fail("fake client has no response at index \{index}")
    }
    result
  })
}

///|
fn fake_tool(name : String, execute : async (String) -> String) -> @tools.Tool {
  {
    schema: {
      name,
      description: "test tool",
      parameters: @tools.object_schema({}, []),
    },
    execute,
  }
}

///|
fn event_name(event : @runtime.EngineEvent) -> String {
  match event {
    ThinkingDelta(_) => "thinking"
    ToolStarted(_) => "tool_started"
    ToolFinished(_) => "tool_finished"
    FinalStarted => "final_started"
    FinalDelta(_) => "final_delta"
    Retrying(_) => "retrying"
    Warning(_) => "warning"
    Error(_) => "error"
  }
}

///|
async test "execute_turn runs a typed tool loop in event order" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [
      response(
        "I will inspect it.",
        tool_calls=[{ id: "call-1", name: "inspect", arguments: "{}" }],
        finish_reason=ToolCalls,
        reasoning="reasoning fallback must not duplicate streamed reasoning",
      ),
      response("done"),
    ],
    [[ReasoningDelta("checking")], []],
    requests,
  )
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [fake_tool("inspect", _ => "{\"ok\":true}")],
    max_tool_calls: 4,
    max_rounds: 3,
    max_tokens: 100,
  }
  let session = agent.new_session()
  let observed : Array[@runtime.EngineEvent] = []
  let answer = agent.execute_turn(client, session, "question", on_event=event => {
    observed.push(event)
  })
  assert_eq(answer.text, "done")
  assert_eq(requests.length(), 2)
  assert_eq(observed.map(event_name), [
    "thinking", "thinking", "tool_started", "tool_finished", "final_started", "final_delta",
  ])
  assert_eq(answer.events, observed)
  assert_eq(session.messages.length(), 5)
}

///|
async test "reasoning response is emitted when a client has no deltas" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [response("answer", reasoning="private reasoning")],
    [[]],
    requests,
  )
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 100,
  }
  let answer = agent.execute(client, "question")
  assert_true(
    answer.events
    is [
      ThinkingDelta({ round: 0, text: "private reasoning" }),
      FinalStarted,
      FinalDelta("answer"),
    ],
  )
}

///|
async test "final continuation emits one combined final delta" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [response("first half", finish_reason=Length), response("second half")],
    [[], []],
    requests,
  )
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 100,
  }
  let answer = agent.execute(client, "question")
  assert_eq(answer.text, "first half\nsecond half")
  assert_eq(requests.length(), 2)
  assert_true(requests[1].tools.is_empty())
  assert_eq(answer.events.map(event_name), ["final_started", "final_delta"])
  guard answer.events is [_, FinalDelta(text)] else {
    fail("expected one final delta")
  }
  assert_eq(text, "first half\nsecond half")
}

///|
async test "tool budget skips excess calls and forces a final request" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [
      response(
        "",
        tool_calls=[
          { id: "one", name: "work", arguments: "1" },
          { id: "two", name: "work", arguments: "2" },
        ],
        finish_reason=ToolCalls,
      ),
      response("budget answer"),
    ],
    [[], []],
    requests,
  )
  let runs = [0]
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [
      fake_tool("work", arguments => {
        runs[0] += 1
        arguments
      }),
    ],
    max_tool_calls: 1,
    max_rounds: 4,
    max_tokens: 100,
  }
  let session = agent.new_session()
  let answer = agent.execute_turn(client, session, "question")
  assert_eq(answer.text, "budget answer")
  assert_eq(runs[0], 1)
  assert_eq(requests.length(), 2)
  assert_true(requests[1].tools.is_empty())
  assert_true(
    session
    .to_json()
    .stringify()
    .contains("tool call skipped: agent budget exhausted"),
  )
}

///|
async test "compact_session summarizes old turns and keeps recent turns" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client([response("summary")], [[]], requests)
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 100,
  }
  let session = @runtime.Session::from_json(
    @model.messages_to_session_json([
      System("system"),
      User("old question"),
      Assistant(content="old answer", tool_calls=[]),
      User("recent question"),
      Assistant(content="recent answer", tool_calls=[]),
    ]),
  )
  agent.compact_session(
    client,
    session,
    threshold_tokens=1,
    keep_recent_turns=1,
  )
  let persisted = session.to_json().stringify()
  assert_true(persisted.contains("(会话摘要) summary"))
  assert_true(persisted.contains("recent question"))
  assert_true(persisted.contains("recent answer"))
  assert_true(!persisted.contains("old question"))
  assert_eq(requests.length(), 1)
}

///|
async test "compaction preserves assistant tool call and result pairs" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client([response("summary")], [[]], requests)
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 100,
  }
  let session = @runtime.Session::from_json(
    @model.messages_to_session_json([
      System("system"),
      User("old"),
      Assistant(content="old answer", tool_calls=[]),
      User("recent"),
      Assistant(content="", tool_calls=[
        { id: "paired", name: "inspect", arguments: "{}" },
      ]),
      Tool(tool_call_id="paired", content="result"),
    ]),
  )
  agent.compact_session(
    client,
    session,
    threshold_tokens=1,
    keep_recent_turns=1,
  )
  let typed = @model.messages_from_session_json(session.to_json())
  assert_true(
    typed
    is [
      _,
      _,
      User("recent"),
      Assistant(tool_calls=[{ id: "paired", .. }], ..),
      Tool(tool_call_id="paired", ..),
    ],
  )
}

///|
async test "three delegated tools run concurrently and preserve result order" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [
      response(
        "",
        tool_calls=[
          { id: "slow", name: "delegate_task", arguments: "slow" },
          { id: "fast", name: "delegate_task", arguments: "fast" },
          { id: "medium", name: "delegate_task", arguments: "medium" },
        ],
        finish_reason=ToolCalls,
      ),
      response("combined"),
    ],
    [[], []],
    requests,
  )
  let active = [0]
  let maximum = [0]
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [
      fake_tool("delegate_task", async fn(arguments) {
        active[0] += 1
        if active[0] > maximum[0] {
          maximum[0] = active[0]
        }
        let delay = match arguments {
          "slow" => 30
          "medium" => 20
          _ => 5
        }
        @async.sleep(delay)
        active[0] -= 1
        arguments
      }),
    ],
    max_tool_calls: 6,
    max_rounds: 3,
    max_tokens: 100,
  }
  let session = agent.new_session()
  let answer = agent.execute_turn(client, session, "question")
  assert_eq(answer.text, "combined")
  assert_eq(maximum[0], 3)
  let results : Array[String] = []
  for message in @model.messages_from_json(session.messages) {
    match message {
      Tool(content~, ..) => results.push(content)
      _ => ()
    }
  }
  assert_eq(results, ["slow", "fast", "medium"])
  let finished : Array[String] = []
  for event in answer.events {
    match event {
      ToolFinished(item) => finished.push(item.call_id)
      _ => ()
    }
  }
  assert_eq(finished, ["slow", "fast", "medium"])
}

///|
async test "client errors propagate after already emitted retry events" {
  let observed : Array[@runtime.EngineEvent] = []
  let client = @model.ChatClient::new(async fn(_, on_model_event) {
    on_model_event(Retrying(attempt=1, reason="connection reset"))
    fail("client boom")
  })
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 100,
  }
  try
    agent.execute(client, "question", on_event=event => observed.push(event))
  catch {
    error => assert_true(error.to_string().contains("client boom"))
  } noraise {
    _ => fail("expected client failure")
  }
  assert_true(
    observed is [Retrying({ attempt: 1, reason: "connection reset" })],
  )
}

///|
async test "regular tool errors propagate without fabricating final output" {
  let requests : Array[@model.ChatRequest] = []
  let client = queued_client(
    [
      response(
        "",
        tool_calls=[{ id: "bad", name: "bad", arguments: "{}" }],
        finish_reason=ToolCalls,
      ),
    ],
    [[]],
    requests,
  )
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [fake_tool("bad", _ => fail("tool boom"))],
    max_tool_calls: 2,
    max_rounds: 2,
    max_tokens: 100,
  }
  try agent.execute(client, "question") catch {
    error => assert_true(error.to_string().contains("tool boom"))
  } noraise {
    _ => fail("expected tool failure")
  }
}

///|
test "Session preserves the existing JSON array persistence contract" {
  let document = Json::array([
    Json::object({
      "role": Json::string("system"),
      "content": Json::string("system"),
    }),
    Json::object({
      "role": Json::string("user"),
      "content": Json::string("hello"),
    }),
  ])
  let session = @runtime.Session::from_json(document)
  assert_eq(session.to_json(), document)
  assert_true(session.char_count() > 0)
  assert_true(session.estimated_tokens() > 0)
}
