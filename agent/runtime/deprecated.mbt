///|
async fn bridge_legacy_events(
  event : EngineEvent,
  on_delta : async (String) -> Unit,
  on_thinking : async (String) -> Unit,
  on_event : async (EngineEvent) -> Unit,
) -> Unit {
  on_event(event)
  match event {
    ThinkingDelta(item) => on_thinking(item.text)
    FinalDelta(text) => on_delta(text)
    _ => ()
  }
}

///|
#deprecated("Use Agent::compact_session with an injected ChatClient", skip_current_package=true)
pub async fn Agent::compact(
  self : Agent,
  session : Session,
  api_key : String,
  base_url : String,
  model : String,
  threshold_tokens? : Int = 8000,
  keep_recent_turns? : Int = 2,
  provider? : @llm.ProviderKind = OpenAi,
) -> Unit {
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  self.compact_session(client, session, threshold_tokens~, keep_recent_turns~)
}

///|
#deprecated("Use Agent::execute with an injected ChatClient", skip_current_package=true)
pub async fn Agent::run(
  self : Agent,
  api_key : String,
  base_url : String,
  model : String,
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  provider? : @llm.ProviderKind = OpenAi,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  self.execute(
    client,
    question,
    on_event=event => {
      bridge_legacy_events(event, on_delta, @llm.ignore_delta, on_event)
    },
    context_window_tokens~,
    reserved_output_tokens~,
  )
}

///|
#deprecated("Use Agent::execute_turn with an injected ChatClient", skip_current_package=true)
pub async fn Agent::turn(
  self : Agent,
  session : Session,
  api_key : String,
  base_url : String,
  model : String,
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  on_thinking? : async (String) -> Unit = @llm.ignore_delta,
  provider? : @llm.ProviderKind = OpenAi,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  self.execute_turn(
    client,
    session,
    question,
    on_event=event => {
      bridge_legacy_events(event, on_delta, on_thinking, on_event)
    },
    context_window_tokens~,
    reserved_output_tokens~,
  )
}
