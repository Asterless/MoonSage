///|
struct LlmAgentAnswer {
  text : String
  trace : Array[String]
}

///|
fn usage() -> String {
  (
    #|MoonSage - an agent for the MoonBit package ecosystem
    #|
    #|Usage:
    #|  moon run cmd/main -- search <keywords>
    #|  moon run cmd/main -- ask <question>
    #|
    #|The ask command reads:
    #|  MOONSAGE_API_KEY    required
    #|  MOONSAGE_BASE_URL   default: https://api.deepseek.com
    #|  MOONSAGE_MODEL      default: deepseek-chat
  )
}

///|
fn join_query(args : Array[String], start : Int) -> String {
  let out = StringBuilder::new()
  let mut index = start
  while index < args.length() {
    if index > start {
      out.write_char(' ')
    }
    out.write_string(args[index])
    index += 1
  }
  out.to_string()
}

///|
async fn fetch_modules() -> Array[@moonsage.ModuleSummary] {
  let (response, body) = @http.get("https://mooncakes.io/api/v0/modules")
  guard response.code == 200 else {
    fail("Mooncakes API returned HTTP \{response.code}")
  }
  @moonsage.parse_modules(body.text())
}

///|
fn argument_string(arguments : String, key : String) -> String raise {
  let document = @json.parse(arguments)
  guard document is Object(fields) else {
    fail("tool arguments must be a JSON object")
  }
  guard fields.get(key) is Some(String(value)) else {
    fail("missing string argument: \{key}")
  }
  value
}

///|
fn search_result_json(
  modules : Array[@moonsage.ModuleSummary],
  arguments : String,
) -> String raise {
  let query = argument_string(arguments, "query")
  @moonsage.search_modules(modules, query, limit=5).to_json().stringify()
}

///|
fn valid_module_name(name : String) -> Bool {
  name.contains("/") &&
  !name.contains("..") &&
  !name.contains("?") &&
  !name.contains("#") &&
  !name.contains("\\")
}

///|
fn valid_asset_value(value : String) -> Bool {
  value != "" &&
  !value.contains("..") &&
  !value.contains("?") &&
  !value.contains("#") &&
  !value.contains("\\")
}

///|
fn package_relpath(name : String, path : String) -> String raise {
  guard valid_asset_value(path) else { fail("invalid Mooncakes package path") }
  let prefix = name + "/"
  if path.has_prefix(prefix) {
    path[prefix.length():].to_owned()
  } else if path == name {
    match name.split_once("/") {
      Some((_, module_path)) => module_path.to_owned()
      None => fail("invalid Mooncakes module name")
    }
  } else {
    path
  }
}

///|
async fn fetch_manifest(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  guard valid_module_name(name) else { fail("invalid Mooncakes module name") }
  fetch_asset(
    "https://mooncakes.io/api/v0/manifest/\{name}",
    "Mooncakes manifest API",
  )
}

///|
async fn fetch_module_index(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  let version = argument_string(arguments, "version")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/module_index.json"
  @moonsage.compact_module_index(fetch_asset(url, "Mooncakes module index"))
}

///|
async fn fetch_package_docs(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  let version = argument_string(arguments, "version")
  let path = argument_string(arguments, "package_path")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let relpath = package_relpath(name, path)
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/\{relpath}/package_data.json"
  @moonsage.compact_package_docs(fetch_asset(url, "Mooncakes package docs"))
}

///|
async fn fetch_asset(url : String, error_label : String) -> String {
  let (response, body) = @http.get(url, headers=asset_headers())
  let text = body.text()
  guard response.code == 200 else {
    fail("\{error_label} returned HTTP \{response.code}")
  }
  text
}

///|
fn error_json(message : String) -> String {
  Json::object({ "error": Json::string(message) }).stringify()
}

///|
fn asset_headers() -> Map[String, String] {
  {
    "Accept": "application/json",
    "User-Agent": "MoonSage/0.1 (+https://mooncakes.io)",
  }
}

///|
fn agent_tools() -> Array[@llm.Tool] {
  [
    @llm.Tool::with_schema(
      "search_modules",
      "Search all Mooncakes modules. Use concise English technical keywords.",
      @llm.Schema::object(
        fields=[
          (
            "query",
            @llm.Schema::string(
              description="English package search keywords, for example: http client",
            ),
          ),
        ],
        required=["query"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_module_manifest",
      "Get live metadata for one exact module, including downloads, versions, build status and license.",
      @llm.Schema::object(
        fields=[
          (
            "name",
            @llm.Schema::string(
              description="Exact owner/module name returned by search_modules",
            ),
          ),
        ],
        required=["name"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_module_index",
      "List packages and public symbol names for an exact module version. Call this before requesting package docs.",
      @llm.Schema::object(
        fields=[
          ("name", @llm.Schema::string(description="Exact owner/module name")),
          (
            "version",
            @llm.Schema::string(description="Exact version from the manifest"),
          ),
        ],
        required=["name", "version"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_package_docs",
      "Get compact public API signatures and docstrings for one package returned by get_module_index.",
      @llm.Schema::object(
        fields=[
          ("name", @llm.Schema::string(description="Exact owner/module name")),
          (
            "version",
            @llm.Schema::string(description="Exact version from the manifest"),
          ),
          (
            "package_path",
            @llm.Schema::string(
              description="Exact full package path returned by get_module_index",
            ),
          ),
        ],
        required=["name", "version", "package_path"],
      ),
    ),
  ]
}

///|
async fn run_llm_agent(
  client : @llm.Client,
  model : String,
  modules : Array[@moonsage.ModuleSummary],
  question : String,
) -> LlmAgentAnswer {
  let conversation = @llm.Conversation::new(
    system=(
      #|You are MoonSage, an agent for the MoonBit package ecosystem.
      #|Use search_modules before recommending packages. Translate user intent
      #|into concise English search keywords. Inspect manifests for the most
      #|relevant candidates before making claims about downloads, versions or
      #|build status. Use get_module_index and get_package_docs before making
      #|claims about APIs, functions, types, examples, or backend suitability.
      #|Do not claim a backend is supported unless the evidence explicitly
      #|shows it. Never invent package facts or API usage. Cite each package with
      #|https://mooncakes.io/docs/<owner>/<module>. Answer in the user's language.
    ),
  )
  conversation.user(question)
  let tools = agent_tools()
  let trace : Array[String] = ["[plan] Delegate package research to the model"]
  let mut step = 0
  let mut total_tool_calls = 0
  let mut package_docs_calls = 0
  while step < 6 {
    let request = conversation.to_request(model).tools(tools).max_tokens(1200)
    let response = client.chat_with_retry(
      request,
      max_retries=2,
      base_delay_ms=500,
    )
    guard response.first() is Some(choice) else {
      fail("model returned no choices")
    }
    let calls = response.tool_calls()
    if calls.is_empty() {
      let text = response.text()
      guard text != "" else { fail("model returned an empty answer") }
      trace.push("[final] Model returned a grounded answer")
      return { text, trace }
    }
    conversation.push(choice.message)
    for call in calls {
      let name = call.function.name
      total_tool_calls += 1
      guard total_tool_calls <= 12 else {
        fail("agent exceeded the 12-call tool budget")
      }
      trace.push("[tool] \{name}")
      let result = match name {
        "search_modules" =>
          search_result_json(modules, call.function.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_module_manifest" =>
          fetch_manifest(call.function.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_module_index" =>
          fetch_module_index(call.function.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_package_docs" => {
          package_docs_calls += 1
          if package_docs_calls > 4 {
            error_json(
              "package docs budget reached; answer using evidence already collected",
            )
          } else {
            fetch_package_docs(call.function.arguments) catch {
              error => error_json(error.to_string())
            }
          }
        }
        _ => error_json("unknown tool: \{name}")
      }
      conversation.tool_result(call.id, result)
      trace.push("[observation] \{name} completed")
    }
    step += 1
  }
  fail("agent exceeded the 6-step tool-call limit")
}

///|
async fn run_search(query : String) -> Unit {
  let modules = fetch_modules()
  let answer = @moonsage.run_agent(modules, query)
  println(@moonsage.render_answer(answer))
}

///|
async fn run_ask(question : String) -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    println("error: set MOONSAGE_API_KEY before using ask")
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let modules = fetch_modules()
  let client = @llm.Client::new(key, base_url~)
  let answer = run_llm_agent(client, model, modules, question)
  println("MoonSage\n")
  for event in answer.trace {
    println(event)
  }
  println("\n\{answer.text}")
}

///|
async fn main {
  let args = cli_args()
  if args.length() < 3 || args[1] == "--help" || args[1] == "-h" {
    println(usage())
    return
  }
  let command = args[1]
  let query = join_query(args, 2)
  match command {
    "search" => run_search(query)
    "ask" => run_ask(query)
    _ => println("Unknown command: \{command}\n\n\{usage()}")
  }
}
