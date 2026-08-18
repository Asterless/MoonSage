///|
#deprecated("Use research_tools from moonsage/agent/research", skip_current_package=true)
pub fn ask_tools(modules : Array[@types.ModuleSummary]) -> Array[@tools.Tool] {
  research_tools(modules)
}

///|
#deprecated("Use research_agent from moonsage/agent/research", skip_current_package=true)
pub fn ask_agent(modules : Array[@types.ModuleSummary]) -> @runtime.Agent {
  research_agent(modules)
}

///|
#deprecated("Use run_research_agent with an injected ChatClient", skip_current_package=true)
pub async fn run_llm_agent(
  api_key : String,
  base_url : String,
  model : String,
  modules : Array[@types.ModuleSummary],
  question : String,
  on_delta? : async (String) -> Unit = @ai.ignore_delta,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  provider? : @ai.ProviderKind = OpenAi,
  extra_tools? : Array[@tools.Tool] = [],
  project_instructions? : String = "",
) -> @runtime.AgentAnswer {
  let client = @ai.client(api_key, base_url, model, provider)
  run_research_agent(
    client,
    modules,
    question,
    on_event=event => {
      on_event(event)
      match event {
        FinalDelta(text) => on_delta(text)
        _ => ()
      }
    },
    extra_tools~,
    project_instructions~,
  )
}
