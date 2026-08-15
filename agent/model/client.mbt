///|
/// A provider-independent asynchronous chat client.
pub struct ChatClient {
  complete_fn : async (ChatRequest, async (ModelEvent) -> Unit) -> ChatResponse
}

///|
/// Build a chat client from an injected completion function.
pub fn ChatClient::new(
  complete : async (ChatRequest, async (ModelEvent) -> Unit) -> ChatResponse,
) -> ChatClient {
  { complete_fn: complete }
}

///|
/// Ignore one incremental model event.
pub async fn ignore_model_event(_event : ModelEvent) -> Unit {
  @async.sleep(0)
}

///|
/// Run one typed chat request.
pub async fn ChatClient::complete(
  self : ChatClient,
  request : ChatRequest,
  on_event? : async (ModelEvent) -> Unit = ignore_model_event,
) -> ChatResponse {
  (self.complete_fn)(request, on_event)
}
