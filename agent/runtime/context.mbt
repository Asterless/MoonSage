///|
fn message_role(message : Json) -> String {
  match message {
    Object(fields) =>
      match fields.get("role") {
        Some(String(role)) => role
        _ => ""
      }
    _ => ""
  }
}

///|
/// Compact older complete turns while retaining the system prompt and recent
/// turns. Typed model messages are created only at the client boundary.
pub async fn Agent::compact_session(
  self : Agent,
  client : @model.ChatClient,
  session : Session,
  threshold_tokens? : Int = 8000,
  keep_recent_turns? : Int = 2,
) -> Unit {
  if session.estimated_tokens() <= threshold_tokens {
    return
  }
  let keep_turns = if keep_recent_turns < 1 { 1 } else { keep_recent_turns }
  let mut cut = session.messages.length() - 1
  let mut seen_users = 0
  while cut > 1 {
    if message_role(session.messages[cut]) == "user" {
      seen_users += 1
      if seen_users >= keep_turns {
        break
      }
    }
    cut -= 1
  }
  if cut <= 1 {
    return
  }
  let transcript = StringBuilder::new()
  for i in 1..<cut {
    transcript.write_string(session.messages[i].stringify())
    transcript.write_string("\n")
  }
  let transcript_text = transcript.to_string()
  let transcript_limit = if threshold_tokens > 64 {
    threshold_tokens
  } else {
    64
  }
  let bounded_transcript = if transcript_text.length() > transcript_limit {
    transcript_text[:transcript_limit].to_owned() + "\n... [history truncated]"
  } else {
    transcript_text
  }
  let summary_tokens = if threshold_tokens / 2 < self.max_tokens {
    if threshold_tokens / 2 > 0 {
      threshold_tokens / 2
    } else {
      1
    }
  } else {
    self.max_tokens
  }
  guard summary_tokens > 0 else {
    fail("context window leaves no room for a compaction summary")
  }
  let summary = client.complete({
    messages: [
      System(
        "Summarize the conversation history into a concise summary that preserves key facts, decisions, file changes and the user's requests. Output only the summary.",
      ),
      User(bounded_transcript),
    ],
    tools: [],
    max_tokens: summary_tokens,
  })
  let new_messages : Array[Json] = [session.messages[0]]
  if summary.content != "" {
    new_messages.push(
      @model.User("(会话摘要) " + summary.content).to_json(),
    )
  } else {
    new_messages.push(
      @model.User(
        "(会话历史过长,部分早期消息已被裁剪;以下为最近的对话)",
      ).to_json(),
    )
  }
  for i in cut..<session.messages.length() {
    new_messages.push(session.messages[i])
  }
  while !session.messages.is_empty() {
    ignore(session.messages.pop())
  }
  for message in new_messages {
    session.messages.push(message)
  }
}

///|
async fn Agent::prepare_context(
  self : Agent,
  client : @model.ChatClient,
  session : Session,
  context_window_tokens : Int,
  reserved_output_tokens : Int,
) -> Unit {
  if context_window_tokens <= 0 {
    return
  }
  let reserve = if reserved_output_tokens > 0 {
    reserved_output_tokens
  } else {
    self.max_tokens
  }
  let input_budget = context_window_tokens - reserve
  guard input_budget > 0 else {
    fail("context window is smaller than the reserved output budget")
  }
  if session.estimated_tokens() > input_budget {
    self.compact_session(client, session, threshold_tokens=input_budget)
  }
  guard session.estimated_tokens() <= input_budget else {
    fail(
      "context budget exceeded after compaction: \{session.estimated_tokens()} > \{input_budget} tokens",
    )
  }
}
