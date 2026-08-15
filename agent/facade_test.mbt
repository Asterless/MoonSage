///|
test "facade re-exports runtime constructors fields and methods" {
  let agent : @agent.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 2,
    max_rounds: 3,
    max_tokens: 100,
  }
  let session : @agent.Session = agent.new_session()
  assert_eq(agent.system_prompt, "system")
  assert_eq(session.messages.length(), 1)
  assert_eq(@agent.Session::from_json(session.to_json()).messages.length(), 1)
  let event : @agent.EngineEvent = ToolStarted({
    round: 0,
    call_id: "call",
    name: "tool",
    arguments: "{}",
  })
  assert_true(event is ToolStarted({ name: "tool", .. }))
  let answer = @agent.AgentAnswer::new("answer", [], [event])
  assert_eq(answer.text, "answer")
  assert_eq(answer.events.length(), 1)
}

///|
#warnings("-deprecated")
async fn old_facade_api_compiles(
  agent : @agent.Agent,
  session : @agent.Session,
) -> Unit {
  if false {
    ignore(agent.run("key", "url", "model", "question"))
    ignore(agent.turn(session, "key", "url", "model", "question"))
    agent.compact(session, "key", "url", "model")
    ignore(@agent.ask_agent([]))
    ignore(@agent.ask_tools([]))
    ignore(@agent.run_llm_agent("key", "url", "model", [], "question"))
  }
}

///|
async test "legacy facade APIs remain source compatible" {
  let agent : @agent.Agent = {
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
  let client = @agent.ChatClient::new((_, _) => {
    content: "answer",
    reasoning: "",
    tool_calls: [],
    finish_reason: Stop,
  })
  let agent : @agent.Agent = {
    system_prompt: "system",
    tools: [],
    max_tool_calls: 1,
    max_rounds: 1,
    max_tokens: 32,
  }
  let answer = agent.execute(client, "question")
  assert_eq(answer.text, "answer")
}
