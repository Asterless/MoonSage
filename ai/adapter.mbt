///|
/// Normalize provider-specific stop reasons for the generic runtime.
pub fn normalize_finish_reason(reason : String?) -> FinishReason {
  match reason {
    None | Some("stop") | Some("end_turn") => Stop
    Some("length") | Some("max_tokens") => Length
    Some("tool_calls") | Some("tool_use") => ToolCalls
    Some(other) => Other(other)
  }
}

///|
fn adapt_response(result : StreamResult) -> ChatResponse {
  {
    content: result.content,
    reasoning: result.reasoning_content,
    tool_calls: result.tool_calls.map(fn(call) {
      { id: call.id, name: call.name, arguments: call.arguments }
    }),
    finish_reason: normalize_finish_reason(result.finish_reason),
  }
}

///|
/// Build a typed chat client backed by the existing provider implementation.
pub fn client(
  api_key : String,
  base_url : String,
  model : String,
  provider : ProviderKind,
) -> ChatClient {
  ChatClient::new(async fn(request, on_event) {
    let result = stream_chat_completion_provider(
      provider,
      api_key,
      base_url,
      model,
      messages_to_json(request.messages),
      tools_to_json(request.tools),
      max_tokens=request.max_tokens,
      on_delta=async fn(text) { on_event(ContentDelta(text)) },
      on_reasoning=async fn(text) { on_event(ReasoningDelta(text)) },
      on_retry=async fn(attempt, reason) {
        on_event(Retrying(attempt~, reason~))
      },
    )
    adapt_response(result)
  })
}
