///|
pub fn Session::to_json(self : Session) -> Json {
  Json::array(self.messages)
}

///|
pub fn Session::from_json(document : Json) -> Session {
  match document {
    Array(items) => { messages: items }
    _ => { messages: [] }
  }
}

///|
pub fn Session::char_count(self : Session) -> Int {
  let mut total = 0
  for message in self.messages {
    total += message.stringify().length()
  }
  total
}

///|
/// Estimate tokens using four ASCII characters per token and one non-ASCII
/// code unit per token. This preserves the existing compaction heuristic.
pub fn Session::estimated_tokens(self : Session) -> Int {
  let mut ascii = 0
  let mut other = 0
  for message in self.messages {
    let text = message.stringify()
    for i in 0..<text.length() {
      if text[i].to_int() < 128 {
        ascii += 1
      } else {
        other += 1
      }
    }
  }
  other + ascii / 4
}

///|
pub fn Agent::new_session(self : Agent) -> Session {
  { messages: [@model.System(self.system_prompt).to_json()] }
}
