///|
fn search_result_json(
  modules : Array[@types.ModuleSummary],
  arguments : String,
) -> String raise {
  let query = @tools.argument_string(arguments, "query")
  @search.search_modules(modules, query, limit=5).to_json().stringify()
}

///|
fn research_system_prompt() -> String {
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
/// Build the Mooncakes research tool set used by ask and conversational
/// agents. Each call receives an independent package-doc budget.
pub fn research_tools(
  modules : Array[@types.ModuleSummary],
) -> Array[@tools.Tool] {
  let package_docs_calls = [0]
  [
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
          error => @tools.error_json(error.to_string())
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
          error => @tools.error_json(error.to_string())
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
          error => @tools.error_json(error.to_string())
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
        package_docs_calls[0] += 1
        if package_docs_calls[0] > 4 {
          @tools.error_json(
            "package docs budget reached; answer using evidence already collected",
          )
        } else {
          @mooncakes.fetch_package_docs(arguments) catch {
            error => @tools.error_json(error.to_string())
          }
        }
      },
    },
  ]
}

///|
/// Assemble the base Mooncakes research agent without delegation.
pub fn research_agent(modules : Array[@types.ModuleSummary]) -> @runtime.Agent {
  {
    system_prompt: research_system_prompt(),
    tools: research_tools(modules),
    max_tool_calls: 12,
    max_rounds: 6,
    max_tokens: 1200,
  }
}

///|
fn delegate_task_tool(
  client : @ai.ChatClient,
  modules : Array[@types.ModuleSummary],
  project_instructions : String,
) -> @tools.Tool {
  {
    schema: {
      name: "delegate_task",
      description: "Run one independent, read-only Mooncakes research task in a subagent. Use only for parallelizable investigations; provide a precise objective and return the evidence to combine in your own answer.",
      parameters: @tools.object_schema(
        { "objective": @tools.string_field("A focused research objective") },
        ["objective"],
      ),
    },
    execute: async fn(arguments) {
      let objective = @tools.argument_string(arguments, "objective") catch {
        error => return @tools.error_json(error.to_string())
      }
      let base_agent = research_agent(modules)
      let subagent : @runtime.Agent = {
        system_prompt: base_agent.system_prompt +
        project_instructions +
        "\nYou are a delegated research subagent. Answer only the assigned objective with concrete evidence for the parent agent. Do not call delegate_task.",
        tools: base_agent.tools,
        max_tool_calls: 8,
        max_rounds: 4,
        max_tokens: 1000,
      }
      let answer = subagent.execute(
        client,
        objective,
        context_window_tokens=32768,
        reserved_output_tokens=1000,
      ) catch {
        error => return @tools.error_json(error.to_string())
      }
      Json::object({ "answer": Json::string(answer.text) }).stringify()
    },
  }
}

///|
fn delegate_task_instruction() -> String {
  (
    #|\nFor independent package research questions, you may use delegate_task.
    #|Delegate only independent, read-only investigations and combine their
    #|evidence yourself. Do not delegate the final answer or the same task
    #|more than once.
  )
}

///|
/// Run the canonical Mooncakes research agent using an injected chat client.
pub async fn run_research_agent(
  client : @ai.ChatClient,
  modules : Array[@types.ModuleSummary],
  question : String,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  extra_tools? : Array[@tools.Tool] = [],
  project_instructions? : String = "",
) -> @runtime.AgentAnswer {
  let base_agent = research_agent(modules)
  let agent : @runtime.Agent = {
    system_prompt: base_agent.system_prompt +
    project_instructions +
    delegate_task_instruction(),
    tools: base_agent.tools +
    [delegate_task_tool(client, modules, project_instructions)] +
    extra_tools,
    max_tool_calls: base_agent.max_tool_calls,
    max_rounds: base_agent.max_rounds,
    max_tokens: base_agent.max_tokens,
  }
  agent.execute(
    client,
    question,
    on_event~,
    context_window_tokens=32768,
    reserved_output_tokens=1200,
  )
}
