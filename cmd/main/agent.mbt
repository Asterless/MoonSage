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
  api_key : String,
  base_url : String,
  model : String,
  modules : Array[@moonsage.ModuleSummary],
  question : String,
  on_delta? : async (String) -> Unit = ignore_delta,
) -> LlmAgentAnswer {
  let messages : Array[Json] = [
    chat_message("system", system_prompt()),
    chat_message("user", question),
  ]
  let tools = agent_tools()
  let tools_json = tools.map(fn(t) { t.to_json() })
  let trace : Array[String] = ["[plan] Delegate package research to the model"]
  let mut step = 0
  let mut total_tool_calls = 0
  let mut package_docs_calls = 0
  let mut budget_exhausted = false
  while step < 6 && !budget_exhausted {
    if total_tool_calls >= 12 {
      budget_exhausted = true
      break
    }
    let result = stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      tools_json,
      max_tokens=1200,
      on_delta~,
    )
    if result.finish_reason is Some("length") {
      trace.push("[observation] Model hit max_tokens; answer may be truncated")
    }
    if result.tool_calls.is_empty() {
      guard result.content != "" else { fail("model returned an empty answer") }
      trace.push("[final] Model returned a grounded answer")
      return { text: result.content, trace }
    }
    messages.push(
      assistant_message_with_tool_calls(result.content, result.tool_calls),
    )
    for call in result.tool_calls {
      if total_tool_calls >= 12 {
        budget_exhausted = true
        // Keep the message history well-formed: every assistant tool call
        // must have a matching tool result, even if we skip executing it.
        messages.push(
          tool_result_message(
            call.id,
            error_json("tool call skipped: agent budget exhausted"),
          ),
        )
        continue
      }
      total_tool_calls += 1
      trace.push("[tool] \{call.name}")
      let call_result = match call.name {
        "search_modules" =>
          search_result_json(modules, call.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_module_manifest" =>
          fetch_manifest(call.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_module_index" =>
          fetch_module_index(call.arguments) catch {
            error => error_json(error.to_string())
          }
        "get_package_docs" => {
          package_docs_calls += 1
          if package_docs_calls > 4 {
            error_json(
              "package docs budget reached; answer using evidence already collected",
            )
          } else {
            fetch_package_docs(call.arguments) catch {
              error => error_json(error.to_string())
            }
          }
        }
        _ => error_json("unknown tool: \{call.name}")
      }
      messages.push(tool_result_message(call.id, call_result))
      trace.push("[observation] \{call.name} completed")
    }
    step += 1
  }
  if !budget_exhausted && step >= 6 {
    budget_exhausted = true
  }
  if budget_exhausted {
    trace.push(
      "[observation] Agent budget exhausted; requesting a final answer from collected evidence",
    )
    messages.push(
      chat_message(
        "user", "(System: no more tool calls are allowed. Answer the user's question now using the evidence already collected.)",
      ),
    )
    let result = stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      tools_json,
      max_tokens=1200,
      on_delta~,
    )
    if result.tool_calls.is_empty() && result.content != "" {
      trace.push("[final] Model answered from collected evidence")
      return { text: result.content, trace }
    }
    fail("model could not answer after exhausting the agent budget")
  }
  fail("agent loop terminated without an answer")
}

///|
fn system_prompt() -> String {
  (
    #|You are MoonSage, an agent for the MoonBit package ecosystem.
    #|Use search_modules before recommending packages. Translate user intent
    #|into concise English search keywords. Inspect manifests for the most
    #|relevant candidates before making claims about downloads, versions or
    #|build status. Use get_module_index and get_package_docs before making
    #|claims about APIs, functions, types, examples, or backend suitability.
    #|Do not claim a backend is supported unless the evidence explicitly
    #|shows it. Never invent package facts or API usage. Cite each package with
    #|https://mooncakes.io/docs/<owner>/<module>. Answer in the user's language.
    #|Conserve tool calls: never repeat a tool with the same arguments, and
    #|stop calling tools as soon as you have enough evidence to answer. You
    #|have a budget of 12 tool calls total; the final answer must be written
    #|from the evidence already collected.
  )
}
