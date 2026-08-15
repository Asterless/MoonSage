///|
test "typed messages preserve the existing session JSON representation" {
  let messages : Array[@model.ChatMessage] = [
    System("system prompt"),
    User("find an HTTP client"),
    Assistant(content="checking", tool_calls=[
      {
        id: "call_1",
        name: "search_modules",
        arguments: "{\"query\":\"http client\"}",
      },
    ]),
    Tool(tool_call_id="call_1", content="{\"matches\":[]}"),
    Assistant(content="done", tool_calls=[]),
  ]
  let document = @model.messages_to_session_json(messages)
  assert_eq(
    document.stringify(),
    "[{\"role\":\"system\",\"content\":\"system prompt\"},{\"role\":\"user\",\"content\":\"find an HTTP client\"},{\"role\":\"assistant\",\"content\":\"checking\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"search_modules\",\"arguments\":\"{\\\"query\\\":\\\"http client\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"{\\\"matches\\\":[]}\"},{\"role\":\"assistant\",\"content\":\"done\"}]",
  )
  assert_eq(@model.messages_from_session_json(document), messages)
}

///|
test "typed model tools round trip through provider schema JSON" {
  let tool : @model.ModelTool = {
    name: "search_modules",
    description: "Search packages",
    parameters: Json::object({
      "type": Json::string("object"),
      "required": Json::array([Json::string("query")]),
    }),
  }
  let encoded = tool.to_json()
  assert_eq(@model.ModelTool::from_json(encoded), tool)
}

///|
async test "ChatClient runs an injected completion and forwards events" {
  let events : Array[@model.ModelEvent] = []
  let client = @model.ChatClient::new(async fn(request, emit) {
    assert_eq(request.max_tokens, 64)
    emit(ReasoningDelta("checking"))
    emit(ContentDelta("answer"))
    {
      content: "answer",
      reasoning: "checking",
      tool_calls: [],
      finish_reason: Stop,
    }
  })
  let response = client.complete(
    { messages: [User("question")], tools: [], max_tokens: 64 },
    on_event=event => events.push(event),
  )
  assert_eq(response.content, "answer")
  assert_eq(events, [ReasoningDelta("checking"), ContentDelta("answer")])
}
