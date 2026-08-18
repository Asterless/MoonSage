///|
test "facade re-exports runtime constructors fields and methods" {
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 2,
    max_rounds: 3,
    max_tokens: 100,
  }
  let session : @runtime.Session = agent.new_session()
  assert_eq(agent.system_prompt, "system")
  assert_eq(session.messages.length(), 1)
  assert_eq(@runtime.Session::from_json(session.to_json()).messages.length(), 1)
  let event : @runtime.EngineEvent = ToolStarted({
    round: 0,
    call_id: "call",
    name: "tool",
    arguments: "{}",
  })
  assert_true(event is ToolStarted({ name: "tool", .. }))
  let answer = @runtime.AgentAnswer::new("answer", [], [event])
  assert_eq(answer.text, "answer")
  assert_eq(answer.events.length(), 1)
}

///|
#warnings("-deprecated")
async fn old_facade_api_compiles(
  agent : @runtime.Agent,
  session : @runtime.Session,
) -> Unit {
  if false {
    ignore(agent.run("key", "url", "model", "question"))
    ignore(agent.turn(session, "key", "url", "model", "question"))
    agent.compact(session, "key", "url", "model")
    ignore(ask_agent([]))
    ignore(ask_tools([]))
    ignore(run_llm_agent("key", "url", "model", [], "question"))
  }
}

///|
async test "legacy facade APIs remain source compatible" {
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 32,
  }
  old_facade_api_compiles(agent, agent.new_session())
}

///|
async test "facade exposes the canonical typed execution API" {
  let client = @ai.ChatClient::new((_, _) => {
    content: "answer",
    reasoning: "",
    tool_calls: [],
    finish_reason: Stop,
  })
  let agent : @runtime.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 32,
  }
  let answer = agent.execute(client, "question")
  assert_eq(answer.text, "answer")
}
