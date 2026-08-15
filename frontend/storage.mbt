///|
let sessions_storage_key : String = "moonsage.web.sessions.v1"

///|
fn json_int_field(
  fields : Map[String, Json],
  name : String,
  default : Int,
) -> Int {
  match fields.get(name) {
    Some(Number(value, ..)) => value.to_int()
    _ => default
  }
}

///|
fn encode_message(message : Message) -> Json {
  Json::object({
    "role": Json::string(message.role),
    "text": Json::string(message.text),
  })
}

///|
fn decode_message(value : Json) -> Message? {
  guard value is Object(fields) else { return None }
  guard fields.get("role") is Some(String(role)) else { return None }
  guard fields.get("text") is Some(String(text)) else { return None }
  Some({ role, text })
}

///|
// Keep at most the tail of the conversation in localStorage so long-running
// sessions do not exhaust the 5 MB quota.
fn tail_messages(messages : Array[Message], limit : Int) -> Array[Message] {
  if messages.length() <= limit {
    return messages
  }
  let start = messages.length() - limit
  let kept : Array[Message] = []
  for index, message in messages {
    if index >= start {
      kept.push(message)
    }
  }
  kept
}

///|
fn encode_session(session : Session) -> Json {
  Json::object({
    "id": Json::string(session.id),
    "title": Json::string(session.title),
    "detail": Json::string(session.detail),
    "messages": Json::array(
      tail_messages(session.messages, 60).map(encode_message),
    ),
  })
}

///|
fn decode_session(value : Json) -> Session? {
  guard value is Object(fields) else { return None }
  guard fields.get("id") is Some(String(id)) else { return None }
  guard fields.get("title") is Some(String(title)) else { return None }
  let detail = json_string_field(fields, "detail")
  let messages = match fields.get("messages") {
    Some(Array(items)) =>
      items.filter_map(fn(item) {
        match decode_message(item) {
          Some(message) => Some(message)
          None => None
        }
      })
    _ => []
  }
  Some({ id, title, detail, messages })
}

///|
fn encode_storage(
  sessions : Array[Session],
  active_session : Int,
  next_id : Int,
) -> String {
  Json::object({
    "version": Json::number(1.0),
    "active_session": Json::number(active_session.to_double()),
    "next_id": Json::number(next_id.to_double()),
    "sessions": Json::array(sessions.map(encode_session)),
  }).stringify()
}

///|
fn decode_storage(source : String) -> (Array[Session], Int, Int)? {
  if source.trim() == "" {
    return None
  }
  guard json_fields(source) is Some(fields) else { return None }
  guard fields.get("sessions") is Some(Array(items)) else { return None }
  let sessions : Array[Session] = []
  for item in items {
    match decode_session(item) {
      Some(session) => sessions.push(session)
      None => ()
    }
  }
  if sessions.is_empty() {
    return None
  }
  let active = json_int_field(fields, "active_session", 0)
  let next_id = json_int_field(fields, "next_id", sessions.length() + 1)
  Some((sessions, active, next_id))
}

///|
extern "js" fn storage_save(key : String, value : String) -> Unit =
  #| (key, value) => { try { localStorage.setItem(key, value); } catch { /* quota or privacy mode */ } }

///|
extern "js" fn storage_load(key : String) -> String =
  #| (key) => { try { return localStorage.getItem(key) ?? ""; } catch { return ""; } }

///|
fn persist_model(model : Model) -> Cmd {
  @cmd.custom_cmd(_ => {
    storage_save(
      sessions_storage_key,
      encode_storage(model.sessions, model.active_session, model.next_id),
    )
  })
}

///|
fn load_persisted_state() -> (Array[Session], Int, Int)? {
  decode_storage(storage_load(sessions_storage_key))
}
