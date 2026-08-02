///|
struct LlmAgentAnswer {
  text : String
  trace : Array[String]
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
fn error_json(message : String) -> String {
  Json::object({ "error": Json::string(message) }).stringify()
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
