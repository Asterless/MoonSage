///|
// 持久会话根目录：<cwd>/.moonsage/sessions。
pub fn session_root(cwd : String) -> String {
  cwd + "/.moonsage/sessions"
}

///|
// 生成会话 id：chat-<epoch 毫秒>。
pub fn generated_session_id(now_ms : Int64) -> String {
  "chat-" + now_ms.to_string()
}

///|
fn session_path(root : String, id : String) -> String {
  root + "/" + id + ".json"
}

///|
// 保存会话到磁盘（覆盖同 id 文件）。
pub async fn save_session(
  root : String,
  id : String,
  session : @agent.Session,
) -> Unit {
  @fs.mkdir(root, recursive=true) catch {
    _ => ()
  }
  let payload = Json::object({
    "id": Json::string(id),
    "messages": session.to_json(),
  }).stringify()
  @fs.write_file(
    session_path(root, id),
    payload,
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    _ => ()
  }
}

///|
// 读取指定会话；不存在或损坏时返回 None。
pub async fn load_session(root : String, id : String) -> @agent.Session? {
  let text = @fs.read_file(session_path(root, id)).text() catch {
    _ => return None
  }
  let document = @json.parse(text) catch { _ => return None }
  guard document is Object(fields) else { return None }
  guard fields.get("messages") is Some(msgs) else { return None }
  Some(@agent.Session::from_json(msgs))
}

///|
// 最近一次会话 id（按 id 里的毫秒时间戳取最大）。
pub async fn latest_session_id(root : String) -> String? {
  let entries = @fs.readdir(root, sort=true) catch { _ => return None }
  let mut best = 0
  let mut best_id : String? = None
  for entry in entries {
    if entry.has_suffix(".json") {
      let id = entry[:entry.length() - 5].to_owned()
      if id.has_prefix("chat-") {
        let ms = @string.parse_int(id[5:]) catch { _ => 0 }
        if ms > best {
          best = ms
          best_id = Some(id)
        }
      }
    }
  }
  best_id
}
