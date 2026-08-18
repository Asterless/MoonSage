///|
let fixture =
  #|[
  #|  {
  #|    "name": "example/http-client",
  #|    "version": "1.2.0",
  #|    "license": "MIT",
  #|    "repository": "https://example.com/http-client",
  #|    "keywords": ["http", "client", "network"],
  #|    "description": "A native HTTP client",
  #|    "created_at": "2026-07-01T00:00:00Z"
  #|  },
  #|  {
  #|    "name": "example/json",
  #|    "version": "0.4.0",
  #|    "license": "Apache-2.0",
  #|    "repository": "",
  #|    "keywords": ["json", "parser"],
  #|    "description": "JSON parsing utilities",
  #|    "created_at": "2026-06-01T00:00:00Z"
  #|  }
  #|]

///|
test "parse Mooncakes module summaries" {
  let modules = @mooncakes.parse_modules(fixture)
  assert_eq(modules.length(), 2)
  assert_eq(modules[0].name, "example/http-client")
  assert_eq(modules[0].keywords, ["http", "client", "network"])
}

///|
test "rank exact module name above description matches" {
  let modules = @mooncakes.parse_modules(fixture)
  let results = search_modules(modules, "http client", limit=1)
  assert_eq(results.length(), 1)
  assert_eq(results[0].item.name, "example/http-client")
  assert_true(results[0].score > 0)
}

///|
test "agent records its plan and tool observation" {
  let modules = @mooncakes.parse_modules(fixture)
  let answer = run_search_agent(modules, "json parser")
  assert_eq(answer.results[0].item.name, "example/json")
  assert_eq(answer.events.length(), 3)
  assert_true(answer.events[0] is @types.Plan(_))
  assert_true(answer.events[1] is @types.ToolCall(_))
  assert_true(answer.events[2] is @types.Observation(_))
}

///|
test "search results serialize for model tool observations" {
  let modules = @mooncakes.parse_modules(fixture)
  let results = search_modules(modules, "json parser")
  let json = results.to_json().stringify()
  assert_true(json.contains("example/json"))
  assert_true(json.contains("Apache-2.0"))
}

///|
test "package_url points at Mooncakes docs" {
  assert_eq(
    package_url("owner/module"),
    "https://mooncakes.io/docs/owner/module",
  )
}

///|
test "render_answer formats events and ranked modules" {
  let modules = @mooncakes.parse_modules(fixture)
  let answer = run_search_agent(modules, "json parser", limit=1)
  let rendered = render_search_answer(answer)
  assert_true(rendered.contains("MoonSage"))
  assert_true(rendered.contains("[plan]"))
  assert_true(rendered.contains("[tool]"))
  assert_true(rendered.contains("[observation]"))
  assert_true(rendered.contains("example/json"))
  assert_true(rendered.contains("https://mooncakes.io/docs/example/json"))
}

///|
test "render_answer handles empty results" {
  let answer = @types.SearchAnswer::{ query: "zzz", events: [], results: [] }
  let rendered = render_search_answer(answer)
  assert_true(rendered.contains("No matching modules found"))
}

///|
test "search modules respects the limit" {
  let modules = @mooncakes.parse_modules(fixture)
  let results = search_modules(modules, "client parser", limit=1)
  assert_eq(results.length(), 1)
}

///|
test "search results break score ties by module name" {
  let modules : Array[@types.ModuleSummary] = [
    @types.ModuleSummary::{
      name: "example/b-widget",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "A widget",
      created_at: "",
    },
    @types.ModuleSummary::{
      name: "example/a-widget",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "A widget",
      created_at: "",
    },
  ]
  let results = search_modules(modules, "widget")
  assert_eq(results[0].item.name, "example/a-widget")
  assert_eq(results[1].item.name, "example/b-widget")
  assert_eq(results[0].score, results[1].score)
}

///|
test "stopword-only query returns no results" {
  let modules = @mooncakes.parse_modules(fixture)
  assert_eq(search_modules(modules, "find package library").length(), 0)
}
