///|
pub fn truncate_batch_text(value : String, max_chars : Int) -> String {
  if max_chars <= 0 {
    return ""
  }
  if value.length() <= max_chars {
    return value
  }
  let marker = "\n... (truncated)"
  if max_chars <= marker.length() {
    return value[:max_chars].to_owned()
  }
  value[:max_chars - marker.length()].to_owned() + marker
}

///|
pub fn redact_batch_text(
  value : String,
  secrets : Array[String],
  max_chars? : Int = 16000,
) -> String {
  let mut output = value
  for secret in secrets {
    if secret != "" && secret.length() >= 4 && secret != "[REDACTED]" {
      output = output.replace_all(old=secret, new="[REDACTED]")
    }
  }
  truncate_batch_text(output, max_chars)
}

///|
pub fn batch_storage_dir(data_root : String) -> String {
  data_root.trim_end(chars="/\\").to_owned() + "/batches"
}

///|
pub fn batch_record_path(data_root : String, batch_id : String) -> String raise {
  validate_storage_id(batch_id)
  batch_storage_dir(data_root) + "/" + batch_id + ".json"
}

///|
pub fn batch_events_path(data_root : String, batch_id : String) -> String raise {
  validate_storage_id(batch_id)
  batch_storage_dir(data_root) + "/" + batch_id + ".jsonl"
}

///|
pub fn batch_control_path(data_root : String, batch_id : String) -> String raise {
  validate_storage_id(batch_id)
  batch_storage_dir(data_root) + "/" + batch_id + ".control.json"
}

///|
pub fn batch_lock_path(data_root : String, batch_id : String) -> String raise {
  validate_storage_id(batch_id)
  batch_storage_dir(data_root) + "/" + batch_id + ".lock"
}

///|
pub fn batch_item_workspace(
  data_root : String,
  batch_id : String,
  item_key : String,
) -> String raise {
  validate_storage_id(batch_id)
  validate_storage_id(item_key)
  batch_storage_dir(data_root) + "/workspaces/" + batch_id + "/" + item_key
}

///|
fn sanitize_json_value(
  value : Json,
  secrets : Array[String],
  max_chars : Int,
) -> Json {
  match value {
    String(text) => Json::string(redact_batch_text(text, secrets, max_chars~))
    Array(values) => Json::array(
      values.map(fn(item) { sanitize_json_value(item, secrets, max_chars) }),
    )
    Object(fields) => {
      let safe : Map[String, Json] = Map([])
      for key, item in fields {
        safe[key] = sanitize_json_value(item, secrets, max_chars)
      }
      Json::object(safe)
    }
    other => other
  }
}

///|
fn safe_record_json(record : BatchRecord, secrets : Array[String]) -> String {
  sanitize_json_value(record.to_json(), secrets, 64000).stringify()
}

///|
/// Persist a record atomically. A temporary sibling is renamed into place so
/// a reader never observes a partially written JSON document.
pub async fn save_batch(
  data_root : String,
  record : BatchRecord,
  secrets? : Array[String] = [],
) -> Unit raise {
  let dir = batch_storage_dir(data_root)
  @fs.mkdir(dir, recursive=true) catch { _ => () }
  let path = batch_record_path(data_root, record.id)
  let temporary = path + ".tmp"
  @fs.write_file(
    temporary,
    safe_record_json(record, secrets),
    create_mode=CreateOrTruncate,
  )
  @fs.rename(temporary, path, replace=true)
}

///|
pub async fn load_batch(data_root : String, batch_id : String) -> BatchRecord? {
  let path = batch_record_path(data_root, batch_id) catch { _ => return None }
  let text = @fs.read_file(path).text() catch { _ => return None }
  let document = @json.parse(text) catch { _ => return None }
  Some(BatchRecord::from_json(document)) catch { _ => return None }
}

///|
pub async fn list_batches(data_root : String) -> Array[BatchRecord] {
  let entries = @fs.readdir(batch_storage_dir(data_root), sort=true) catch {
    _ => return []
  }
  let records : Array[BatchRecord] = []
  for entry in entries {
    if entry.has_suffix(".json") &&
      !entry.has_suffix(".control.json") {
      let id = entry[:entry.length() - 5].to_owned()
      let record = load_batch(data_root, id)
      match record {
        Some(value) => records.push(value)
        None => ()
      }
    }
  }
  records.sort_by(fn(a, b) {
    let order = Int64::compare(b.created_at_ms, a.created_at_ms)
    if order == 0 { a.id.compare(b.id) } else { order }
  })
  records
}

///|
fn safe_event_json(event : BatchEvent, secrets : Array[String]) -> String {
  sanitize_json_value(event.to_json(), secrets, 16000).stringify()
}

///|
/// Append one bounded, redacted JSONL event. The file is intentionally opened
/// in append mode so concurrent readers can stream it without truncation.
pub async fn append_batch_event(
  data_root : String,
  event : BatchEvent,
  secrets? : Array[String] = [],
) -> Unit raise {
  let dir = batch_storage_dir(data_root)
  @fs.mkdir(dir, recursive=true) catch { _ => () }
  @fs.write_file(
    batch_events_path(data_root, event.batch_id),
    safe_event_json(event, secrets) + "\n",
    create_mode=OpenOrCreate,
    append=true,
  )
}

///|
pub async fn load_batch_events(
  data_root : String,
  batch_id : String,
) -> Array[BatchEvent] {
  let path = batch_events_path(data_root, batch_id) catch { _ => return [] }
  let text = @fs.read_file(path).text() catch { _ => return [] }
  let events : Array[BatchEvent] = []
  for line_view in text.split("\n") {
    let line = line_view.trim().to_owned()
    if line == "" {
      continue
    }
    let event = @json.parse(line) catch { _ => continue }
    let parsed = BatchEvent::from_json(event) catch { _ => continue }
    events.push(parsed)
  }
  events
}

///|
pub async fn save_batch_control(
  data_root : String,
  batch_id : String,
  control : BatchControl,
) -> Unit raise {
  @fs.mkdir(batch_storage_dir(data_root), recursive=true) catch { _ => () }
  @fs.write_file(
    batch_control_path(data_root, batch_id),
    control.to_json().stringify(),
    create_mode=CreateOrTruncate,
  )
}

///|
pub async fn load_batch_control(
  data_root : String,
  batch_id : String,
) -> BatchControl {
  let path = batch_control_path(data_root, batch_id) catch {
    _ => return empty_batch_control()
  }
  let text = @fs.read_file(path).text() catch {
    _ => return empty_batch_control()
  }
  let document = @json.parse(text) catch { _ => return empty_batch_control() }
  BatchControl::from_json(document) catch { _ => empty_batch_control() }
}

///|
pub async fn clear_batch_control(data_root : String, batch_id : String) -> Unit {
  let path = batch_control_path(data_root, batch_id) catch { _ => return }
  @fs.remove(path) catch { _ => () }
}

///|
/// Acquire the per-batch advisory lock. `CreateNew` makes this safe against
/// two workers starting the same batch at the same time.
pub async fn try_acquire_batch_lock(
  data_root : String,
  batch_id : String,
  owner : String,
) -> Bool {
  let path = batch_lock_path(data_root, batch_id) catch { _ => return false }
  @fs.mkdir(batch_storage_dir(data_root), recursive=true) catch { _ => () }
  @fs.write_file(
    path,
    redact_batch_text(owner, [], max_chars=256) + "\n",
    create_mode=CreateNew,
  ) catch {
    _ => return false
  }
  true
}

///|
pub async fn release_batch_lock(data_root : String, batch_id : String) -> Unit {
  let path = batch_lock_path(data_root, batch_id) catch { _ => return }
  @fs.remove(path) catch { _ => () }
}
