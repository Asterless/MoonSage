///|
test "slash_command classifies input" {
  assert_true(slash_command("/exit") is Exit)
  assert_true(slash_command("/quit") is Exit)
  assert_true(slash_command("exit") is Exit)
  assert_true(slash_command("quit") is Exit)
  assert_true(slash_command("/clear") is Clear)
  assert_true(slash_command("/help") is Help)
  assert_true(slash_command("你好") is Prompt)
  assert_true(slash_command("") is Prompt)
}

///|
test "chat agent combines ask and local tools" {
  let agent = chat_agent([], "C:/work", @editing.Workspace::new("C:/work"))
  assert_eq(agent.tools.length(), 13)
  let names = agent.tools.map(fn(t) { t.schema.name })
  assert_true(names.contains("search_modules"))
  assert_true(names.contains("get_module_manifest"))
  assert_true(names.contains("get_module_index"))
  assert_true(names.contains("get_package_docs"))
  assert_true(names.contains("list_project_files"))
  assert_true(names.contains("read_file"))
  assert_true(names.contains("run_moon"))
  assert_true(names.contains("git_diff"))
  assert_true(names.contains("write_file"))
  assert_true(names.contains("multi_edit"))
  assert_true(names.contains("remove"))
  assert_true(names.contains("clone_repo"))
  assert_true(names.contains("create_pr"))
  assert_eq(agent.max_tool_calls, 30)
  assert_eq(agent.max_rounds, 10)
  assert_true(agent.max_tokens > 0)
}

///|
test "utf8_or_gbk passes valid UTF-8 through unchanged" {
  let utf8 = b"\xe4\xbd\xa0\xe5\xa5\xbd" // 你好
  assert_eq(utf8_or_gbk(utf8, utf8.length()), "你好")
  // 带 UTF-8 BOM 的输入也应正确剥离
  assert_eq(utf8_or_gbk(b"\xef\xbb\xbf" + utf8, utf8.length() + 3), "你好")
}

///|
#cfg(platform="windows")
test "utf8_or_gbk converts GBK bytes on the system codepage" {
  let gbk = b"\xc4\xe3\xba\xc3" // 你好 (GBK)
  assert_eq(utf8_or_gbk(gbk, gbk.length()), "你好")
  // BOM + GBK 的组合（部分管道会在输入前附加 UTF-8 BOM）
  assert_eq(utf8_or_gbk(b"\xef\xbb\xbf" + gbk, gbk.length() + 3), "你好")
}

///|
async test "session store round-trips and picks latest" {
  let root = @fs.tmpdir(prefix="moonsage-session-test-")
  let agent = chat_agent([], "C:/work", @editing.Workspace::new("C:/work"))
  let s1 = agent.new_session()
  let s2 = agent.new_session()
  // 旧格式会话没有 ws_root 字段，应回退为空字符串。
  @fs.write_file(
    root + "/chat-100.json",
    Json::object({ "id": Json::string("chat-100"), "messages": s1.to_json() }).stringify(),
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  save_session(root, "chat-200", s2, "C:/work/.moonsage/workspaces/repo")
  let loaded = load_session(root, "chat-200")
  guard loaded is Some(saved) else {
    assert_true(false)
    @fs.rmdir(root, recursive=true) catch {
      _ => ()
    }
    return
  }
  assert_eq(saved.messages.length(), s2.messages.length())
  let with_root = load_session_with_root(root, "chat-200")
  guard with_root is Some(saved_full) else {
    assert_true(false)
    @fs.rmdir(root, recursive=true) catch {
      _ => ()
    }
    return
  }
  assert_eq(saved_full.ws_root, "C:/work/.moonsage/workspaces/repo")
  let old_style = load_session_with_root(root, "chat-100")
  guard old_style is Some(old_full) else {
    assert_true(false)
    @fs.rmdir(root, recursive=true) catch {
      _ => ()
    }
    return
  }
  assert_eq(old_full.ws_root, "")
  assert_eq(latest_session_id(root), Some("chat-200"))
  assert_true(load_session(root, "chat-missing") is None)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
