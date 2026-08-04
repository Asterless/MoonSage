///|
pub(all) struct Agent {
  system_prompt : String
  tools : Array[@tools.Tool]
  max_tool_calls : Int
  max_rounds : Int
  max_tokens : Int
}

///|
pub struct AgentAnswer {
  text : String
  trace : Array[String]
}

///|
// Generic LLM tool-calling loop. Sends the request, executes tool calls via
// the Agent's tool registry, respects the tool-call/round budget, and forces
// a plain-text final answer once the budget is exhausted (no tools exposed).
pub async fn Agent::run(
  self : Agent,
  api_key : String,
  base_url : String,
  model : String,
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
) -> AgentAnswer {
  let messages : Array[Json] = [
    @llm.chat_message("system", self.system_prompt),
    @llm.chat_message("user", question),
  ]
  let tools_json = self.tools.map(fn(t) { t.schema.to_json() })
  let trace : Array[String] = ["[plan] Delegate the task to the model"]
  let mut step = 0
  let mut total_tool_calls = 0
  let mut budget_exhausted = false
  while step < self.max_rounds && !budget_exhausted {
    if total_tool_calls >= self.max_tool_calls {
      budget_exhausted = true
      break
    }
    let result = @llm.stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      tools_json,
      max_tokens=self.max_tokens,
      on_delta~,
    )
    if result.finish_reason is Some("length") {
      trace.push("[observation] Model hit max_tokens; answer may be truncated")
    }
    if result.tool_calls.is_empty() {
      guard result.content != "" else { fail("model returned an empty answer") }
      trace.push("[final] Model returned an answer")
      return { text: result.content, trace }
    }
    messages.push(
      @llm.assistant_message_with_tool_calls(result.content, result.tool_calls),
    )
    for call in result.tool_calls {
      if total_tool_calls >= self.max_tool_calls {
        budget_exhausted = true
        // Keep the message history well-formed: every assistant tool call
        // must have a matching tool result, even if we skip executing it.
        messages.push(
          @llm.tool_result_message(
            call.id,
            @tools.error_json("tool call skipped: agent budget exhausted"),
          ),
        )
        continue
      }
      total_tool_calls += 1
      trace.push("[tool] \{call.name}")
      let call_result = match @tools.find_tool(self.tools, call.name) {
        Some(tool) => tool.run(call.arguments)
        None => @tools.error_json("unknown tool: \{call.name}")
      }
      messages.push(@llm.tool_result_message(call.id, call_result))
      trace.push("[observation] \{call.name} completed")
    }
    step += 1
  }
  if !budget_exhausted && step >= self.max_rounds {
    budget_exhausted = true
  }
  if budget_exhausted {
    trace.push(
      "[observation] Agent budget exhausted; requesting a final answer from collected evidence",
    )
    messages.push(
      @llm.chat_message(
        "user", "(System: no more tool calls are allowed. Answer the user's question now using the evidence already collected.)",
      ),
    )
    // ?????????????????????
    let result = @llm.stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      [],
      max_tokens=self.max_tokens,
      on_delta~,
    )
    if result.content != "" {
      trace.push("[final] Model answered from collected evidence")
      return { text: result.content, trace }
    }
    fail("model could not answer after exhausting the agent budget")
  }
  fail("agent loop terminated without an answer")
}

///|
fn search_result_json(
  modules : Array[@moonsage.ModuleSummary],
  arguments : String,
) -> String raise {
  let query = @tools.argument_string(arguments, "query")
  @moonsage.search_modules(modules, query, limit=5).to_json().stringify()
}

///|
fn ask_system_prompt() -> String {
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

///|
// The `ask` agent: research Mooncakes packages and recommend candidates.
pub fn ask_agent(modules : Array[@moonsage.ModuleSummary]) -> Agent {
  let mut package_docs_calls = 0
  {
    system_prompt: ask_system_prompt(),
    tools: [
      {
        schema: {
          name: "search_modules",
          description: "Search all Mooncakes modules. Use concise English technical keywords.",
          parameters: @tools.object_schema(
            {
              "query": @tools.string_field(
                "English package search keywords, for example: http client",
              ),
            },
            ["query"],
          ),
        },
        execute: async fn(arguments) {
          let result = search_result_json(modules, arguments) catch {
            e => @tools.error_json(e.to_string())
          }
          @async.sleep(0)
          result
        },
      },
      {
        schema: {
          name: "get_module_manifest",
          description: "Get live metadata for one exact module, including downloads, versions, build status and license.",
          parameters: @tools.object_schema(
            {
              "name": @tools.string_field(
                "Exact owner/module name returned by search_modules",
              ),
            },
            ["name"],
          ),
        },
        execute: async fn(arguments) {
          @mooncakes.fetch_manifest(arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        },
      },
      {
        schema: {
          name: "get_module_index",
          description: "List packages and public symbol names for an exact module version. Call this before requesting package docs.",
          parameters: @tools.object_schema(
            {
              "name": @tools.string_field("Exact owner/module name"),
              "version": @tools.string_field("Exact version from the manifest"),
            },
            ["name", "version"],
          ),
        },
        execute: async fn(arguments) {
          @mooncakes.fetch_module_index(arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        },
      },
      {
        schema: {
          name: "get_package_docs",
          description: "Get compact public API signatures and docstrings for one package returned by get_module_index.",
          parameters: @tools.object_schema(
            {
              "name": @tools.string_field("Exact owner/module name"),
              "version": @tools.string_field("Exact version from the manifest"),
              "package_path": @tools.string_field(
                "Exact full package path returned by get_module_index",
              ),
            },
            ["name", "version", "package_path"],
          ),
        },
        execute: async fn(arguments) {
          package_docs_calls += 1
          if package_docs_calls > 4 {
            @tools.error_json(
              "package docs budget reached; answer using evidence already collected",
            )
          } else {
            @mooncakes.fetch_package_docs(arguments) catch {
              e => @tools.error_json(e.to_string())
            }
          }
        },
      },
    ],
    max_tool_calls: 12,
    max_rounds: 6,
    max_tokens: 1200,
  }
}

///|
// Convenience entry point for the `ask` command.
pub async fn run_llm_agent(
  api_key : String,
  base_url : String,
  model : String,
  modules : Array[@moonsage.ModuleSummary],
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
) -> AgentAnswer {
  ask_agent(modules).run(api_key, base_url, model, question, on_delta~)
}
