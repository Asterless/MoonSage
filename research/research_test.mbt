///|
fn module_fixture() -> Array[@types.ModuleSummary] {
  [
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
}

///|
test "research_agent exposes four research tools with the research budget" {
  let agent = @research.research_agent(module_fixture())
  assert_eq(agent.max_tool_calls, 12)
  assert_eq(agent.max_rounds, 6)
  assert_eq(agent.tools.map(tool => tool.schema.name), [
    "search_modules", "get_module_manifest", "get_module_index", "get_package_docs",
  ])
}

///|
async test "run_research_agent executes search then returns final answer" {
  let turn = [0]
  let requests : Array[@ai.ChatRequest] = []
  let client = @ai.ChatClient::new((request, _) => {
    requests.push(request)
    let index = turn[0]
    turn[0] += 1
    if index == 0 {
      {
        content: "searching",
        reasoning: "",
        tool_calls: [
          {
            id: "search-1",
            name: "search_modules",
            arguments: "{\"query\":\"http\"}",
          },
        ],
        finish_reason: ToolCalls,
      }
    } else {
      {
        content: "Found it",
        reasoning: "",
        tool_calls: [],
        finish_reason: Stop,
      }
    }
  })
  let answer = @research.run_research_agent(
    client,
    module_fixture(),
    "find http client",
  )
  assert_eq(answer.text, "Found it")
  assert_true(answer.trace.contains("[tool] search_modules"))
  assert_eq(requests.length(), 2)
  assert_true(requests[0].tools.length() == 5)
}

///|
async test "research tools return search errors as structured tool results" {
  let search = @research.research_tools(module_fixture())[0]
  let result = search.run("{}")
  assert_true(result.contains("error"))
  assert_true(result.contains("missing string argument"))
}
