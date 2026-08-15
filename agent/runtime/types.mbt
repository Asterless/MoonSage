///|
/// Configuration for the provider-independent agent runtime.
pub(all) struct Agent {
  system_prompt : String
  tools : Array[@tools.Tool]
  max_tool_calls : Int
  max_rounds : Int
  max_tokens : Int
}

///|
/// Persisted conversation state. Messages intentionally remain in the
/// existing JSON representation so saved sessions require no migration.
pub(all) struct Session {
  messages : Array[Json]
}

///|
pub(all) struct ThinkingDeltaEvent {
  round : Int
  text : String
} derive(Eq, Debug)

///|
pub(all) struct ToolStartedEvent {
  round : Int
  call_id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
pub(all) struct ToolFinishedEvent {
  round : Int
  call_id : String
  name : String
  status : String
  result : String
} derive(Eq, Debug)

///|
pub(all) struct RetryEvent {
  attempt : Int
  reason : String
} derive(Eq, Debug)

///|
/// The only observation channel exposed by the generic runtime.
pub(all) enum EngineEvent {
  ThinkingDelta(ThinkingDeltaEvent)
  ToolStarted(ToolStartedEvent)
  ToolFinished(ToolFinishedEvent)
  FinalStarted
  FinalDelta(String)
  Retrying(RetryEvent)
  Warning(String)
  Error(String)
} derive(Eq, Debug)

///|
pub async fn ignore_event(_event : EngineEvent) -> Unit {
  @async.sleep(0)
}

///|
pub struct AgentAnswer {
  text : String
  trace : Array[String]
  events : Array[EngineEvent]
}

///|
pub fn AgentAnswer::new(
  text : String,
  trace : Array[String],
  events : Array[EngineEvent],
) -> AgentAnswer {
  { text, trace, events }
}
