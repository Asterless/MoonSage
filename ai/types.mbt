///|
/// One provider-neutral tool call requested by a chat model.
pub(all) struct ModelToolCall {
  id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
/// A provider-neutral function tool exposed to a chat model.
pub(all) struct ModelTool {
  name : String
  description : String
  parameters : Json
} derive(Eq, Debug)

///|
/// A typed chat message. Its JSON conversion intentionally matches the
/// OpenAI-style array format used by existing MoonSage session files.
pub(all) enum ChatMessage {
  System(String)
  User(String)
  Assistant(content~ : String, tool_calls~ : Array[ModelToolCall])
  Tool(tool_call_id~ : String, content~ : String)
} derive(Eq, Debug)

///|
/// One provider-neutral chat request.
pub(all) struct ChatRequest {
  messages : Array[ChatMessage]
  tools : Array[ModelTool]
  max_tokens : Int
} derive(Eq, Debug)

///|
/// Why a model stopped producing its response.
pub(all) enum FinishReason {
  Stop
  Length
  ToolCalls
  Other(String)
} derive(Eq, Debug)

///|
/// A normalized chat response returned by a `ChatClient`.
pub(all) struct ChatResponse {
  content : String
  reasoning : String
  tool_calls : Array[ModelToolCall]
  finish_reason : FinishReason
} derive(Eq, Debug)

///|
/// Incremental observations emitted while a chat request is running.
pub(all) enum ModelEvent {
  ContentDelta(String)
  ReasoningDelta(String)
  Retrying(attempt~ : Int, reason~ : String)
} derive(Eq, Debug)
