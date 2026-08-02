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
  let modules = @moonsage.parse_modules(fixture)
  assert_eq(modules.length(), 2)
  assert_eq(modules[0].name, "example/http-client")
  assert_eq(modules[0].keywords, ["http", "client", "network"])
}

///|
test "rank exact module name above description matches" {
  let modules = @moonsage.parse_modules(fixture)
  let results = @moonsage.search_modules(modules, "http client", limit=1)
  assert_eq(results.length(), 1)
  assert_eq(results[0].item.name, "example/http-client")
  assert_true(results[0].score > 0)
}

///|
test "agent records its plan and tool observation" {
  let modules = @moonsage.parse_modules(fixture)
  let answer = @moonsage.run_agent(modules, "json parser")
  assert_eq(answer.results[0].item.name, "example/json")
  assert_eq(answer.events.length(), 3)
  assert_true(answer.events[0] is Plan(_))
  assert_true(answer.events[1] is ToolCall(_))
  assert_true(answer.events[2] is Observation(_))
}

///|
test "search results serialize for model tool observations" {
  let modules = @moonsage.parse_modules(fixture)
  let results = @moonsage.search_modules(modules, "json parser")
  let json = results.to_json().stringify()
  assert_true(json.contains("example/json"))
  assert_true(json.contains("Apache-2.0"))
}

///|
test "compact module index keeps package paths and public symbols" {
  let input =
    #|{
    #|  "name": "owner",
    #|  "package": null,
    #|  "childs": [{
    #|    "name": "module",
    #|    "package": null,
    #|    "childs": [{
    #|      "name": "client",
    #|      "package": {
    #|        "path": "owner/module/client",
    #|        "traits": [{"name": "Transport"}],
    #|        "errors": [{"name": "ClientError"}],
    #|        "types": [{"name": "Client"}],
    #|        "values": ["connect"]
    #|      },
    #|      "childs": []
    #|    }]
    #|  }]
    #|}
  let result = @moonsage.compact_module_index(input)
  assert_true(result.contains("owner/module/client"))
  assert_true(result.contains("Transport"))
  assert_true(result.contains("Client"))
  assert_true(result.contains("connect"))
}

///|
test "compact package docs keeps signatures and methods" {
  let input =
    #|{
    #|  "name": "owner/module/client",
    #|  "traits": [],
    #|  "errors": [],
    #|  "types": [{
    #|    "name": "Client",
    #|    "docstring": "An HTTP client.",
    #|    "signature": "pub struct Client",
    #|    "methods": [{
    #|      "name": "send",
    #|      "docstring": "Send one request.",
    #|      "signature": "async fn Client::send(Self, Request) -> Response"
    #|    }]
    #|  }],
    #|  "values": [{
    #|    "name": "connect",
    #|    "docstring": "Open a connection.",
    #|    "signature": "async fn connect(String) -> Client"
    #|  }]
    #|}
  let result = @moonsage.compact_package_docs(input)
  assert_true(result.contains("Client::send"))
  assert_true(result.contains("Send one request."))
  assert_true(result.contains("async fn connect"))
}

///|
test "package_url points at Mooncakes docs" {
  assert_eq(
    @moonsage.package_url("owner/module"),
    "https://mooncakes.io/docs/owner/module",
  )
}

///|
test "render_answer formats events and ranked modules" {
  let modules = @moonsage.parse_modules(fixture)
  let answer = @moonsage.run_agent(modules, "json parser", limit=1)
  let rendered = @moonsage.render_answer(answer)
  assert_true(rendered.contains("MoonSage"))
  assert_true(rendered.contains("[plan]"))
  assert_true(rendered.contains("[tool]"))
  assert_true(rendered.contains("[observation]"))
  assert_true(rendered.contains("example/json"))
  assert_true(rendered.contains("https://mooncakes.io/docs/example/json"))
}

///|
test "render_answer handles empty results" {
  let answer = @moonsage.AgentAnswer::{ query: "zzz", events: [], results: [] }
  let rendered = @moonsage.render_answer(answer)
  assert_true(rendered.contains("No matching modules found"))
}

///|
test "search modules respects the limit" {
  let modules = @moonsage.parse_modules(fixture)
  let results = @moonsage.search_modules(modules, "client parser", limit=1)
  assert_eq(results.length(), 1)
}

///|
test "search results break score ties by module name" {
  let modules : Array[@moonsage.ModuleSummary] = [
    {
      name: "example/b-widget",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "A widget",
      created_at: "",
    },
    {
      name: "example/a-widget",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "A widget",
      created_at: "",
    },
  ]
  let results = @moonsage.search_modules(modules, "widget")
  assert_eq(results[0].item.name, "example/a-widget")
  assert_eq(results[1].item.name, "example/b-widget")
  assert_eq(results[0].score, results[1].score)
}

///|
test "stopword-only query returns no results" {
  let modules = @moonsage.parse_modules(fixture)
  assert_eq(
    @moonsage.search_modules(modules, "find package library").length(),
    0,
  )
}

///|
test "compact module index caps at 80 packages" {
  let packages : Array[Json] = []
  for i = 0; i < 81; i = i + 1 {
    packages.push(
      Json::object({
        "name": Json::string("package\{i}"),
        "package": Json::object({
          "path": Json::string("owner/module/package\{i}"),
          "traits": Json::array([]),
          "errors": Json::array([]),
          "types": Json::array([]),
          "values": Json::array([]),
        }),
        "childs": Json::array([]),
      }),
    )
  }
  let root = Json::object({
    "name": Json::string("owner"),
    "package": Json::null(),
    "childs": Json::array([
      Json::object({
        "name": Json::string("module"),
        "package": Json::null(),
        "childs": Json::array(packages),
      }),
    ]),
  })
  let result = @moonsage.compact_module_index(root.stringify())
  assert_true(result.contains("package79"))
  assert_true(!result.contains("package80"))
}

///|
test "compact package docs caps at 100 entries" {
  let types : Array[Json] = []
  for i = 0; i < 101; i = i + 1 {
    types.push(
      Json::object({
        "name": Json::string("Type\{i}"),
        "docstring": Json::string(""),
        "signature": Json::string("pub struct Type\{i}"),
        "methods": Json::array([]),
      }),
    )
  }
  let doc = Json::object({
    "name": Json::string("owner/module/client"),
    "traits": Json::array([]),
    "errors": Json::array([]),
    "types": Json::array(types),
    "values": Json::array([]),
  })
  let result = @moonsage.compact_package_docs(doc.stringify())
  assert_true(result.contains("Type99"))
  assert_true(!result.contains("Type100"))
}

///|
test "compact package docs rejects non-object input" {
  let raised = try {
    ignore(@moonsage.compact_package_docs("[]"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "parse modules rejects non-array input" {
  let raised = try {
    ignore(@moonsage.parse_modules("{}"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
