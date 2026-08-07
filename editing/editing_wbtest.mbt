///|
test "apply_edits_to_file replaces a single match" {
  let content = "pub fn a() {}\npub fn b() {}\n"
  let result = apply_edits_to_file(content, [
    {
      file: "x.mbt",
      old_string: "pub fn b() {}",
      new_string: "pub fn c() {}",
      start_line: 1,
      end_line: 0,
    },
  ])
  assert_eq(result, "pub fn a() {}\npub fn c() {}\n")
}

///|
test "apply_edits_to_file rejects no match" {
  let raised = try {
    ignore(
      apply_edits_to_file("abc\n", [
        {
          file: "x",
          old_string: "zzz",
          new_string: "y",
          start_line: 1,
          end_line: 0,
        },
      ]),
    )
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "apply_edits_to_file rejects ambiguous match" {
  let raised = try {
    ignore(
      apply_edits_to_file("x y x\n", [
        {
          file: "x",
          old_string: "x",
          new_string: "z",
          start_line: 1,
          end_line: 0,
        },
      ]),
    )
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "apply_edits_to_file anchors by line range" {
  let result = apply_edits_to_file("x\nx\n", [
    { file: "x", old_string: "x", new_string: "y", start_line: 2, end_line: 2 },
  ])
  assert_eq(result, "x\ny\n")
}

///|
test "apply_edits_to_file inserts at line start" {
  let result = apply_edits_to_file("a\nb\n", [
    {
      file: "x",
      old_string: "",
      new_string: "// note\n",
      start_line: 2,
      end_line: 0,
    },
  ])
  assert_eq(result, "a\n// note\nb\n")
}

///|
test "apply_edits_to_file appends past end of file" {
  let result = apply_edits_to_file("a\n", [
    {
      file: "x",
      old_string: "",
      new_string: "b\n",
      start_line: 99,
      end_line: 0,
    },
  ])
  assert_eq(result, "a\nb\n")
}

///|
test "apply_edits_to_file rejects overlapping edits" {
  let raised = try {
    ignore(
      apply_edits_to_file("abcdef\n", [
        {
          file: "x",
          old_string: "abc",
          new_string: "1",
          start_line: 1,
          end_line: 0,
        },
        {
          file: "x",
          old_string: "bcd",
          new_string: "2",
          start_line: 1,
          end_line: 0,
        },
      ]),
    )
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "apply_edits_to_file applies multiple edits bottom-up" {
  let result = apply_edits_to_file("a\nb\nc\n", [
    { file: "x", old_string: "a", new_string: "A", start_line: 1, end_line: 0 },
    { file: "x", old_string: "c", new_string: "C", start_line: 3, end_line: 0 },
  ])
  assert_eq(result, "A\nb\nC\n")
}

///|
test "apply_edits_to_file matches LF old_string against CRLF content" {
  let content = "pub fn a() {}\r\npub fn b() {}\r\n"
  let result = apply_edits_to_file(content, [
    {
      file: "x",
      old_string: "pub fn b() {}",
      new_string: "pub fn c() {}",
      start_line: 1,
      end_line: 0,
    },
  ])
  // 输出保留 CRLF，替换文本也统一为 CRLF。
  assert_eq(result, "pub fn a() {}\r\npub fn c() {}\r\n")
}

///|
test "apply_edits_to_file matches CRLF old_string against LF content" {
  let result = apply_edits_to_file("a\nb\n", [
    {
      file: "x",
      old_string: "a\r\n",
      new_string: "A\r\n",
      start_line: 1,
      end_line: 0,
    },
  ])
  // LF 文件：新文本换行统一为 LF。
  assert_eq(result, "A\nb\n")
}

///|
test "apply_edits_to_file insertion adopts file EOL style" {
  let result = apply_edits_to_file("a\r\nb\r\n", [
    {
      file: "x",
      old_string: "",
      new_string: "// note\n",
      start_line: 1,
      end_line: 0,
    },
  ])
  assert_eq(result, "// note\r\na\r\nb\r\n")
}

///|
async test "multi_edit_tool applies edits atomically with syntax gate" {
  let tmp = @fs.tmpdir(prefix="moonsage-edit-test-")
  let _ = @fs.write_file(
    tmp + "/a.mbt",
    "pub fn old() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = multi_edit_tool(
    Workspace::new(tmp),
    Auto,
    "{\"edits\":[{\"file\":\"a.mbt\",\"old_string\":\"pub fn old() {}\",\"new_string\":\"pub fn new() {}\",\"start_line\":1}]}",
  )
  assert_true(ok.contains("applied"))
  assert_true(@fs.read_file(tmp + "/a.mbt").text().contains("pub fn new()"))
  // 语法门拒绝：修改后无法解析，整批不落盘。
  let bad = try {
    ignore(
      multi_edit_tool(
        Workspace::new(tmp),
        Auto,
        "{\"edits\":[{\"file\":\"a.mbt\",\"old_string\":\"pub fn new() {}\",\"new_string\":\"fn bad( {\",\"start_line\":1}]}",
      ),
    )
    false
  } catch {
    e => e.to_string().contains("语法检查")
  }
  assert_true(bad)
  assert_true(@fs.read_file(tmp + "/a.mbt").text().contains("pub fn new()"))
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "remove_tool deletes files within workspace only" {
  let tmp = @fs.tmpdir(prefix="moonsage-remove-test-")
  let _ = @fs.write_file(
    tmp + "/gone.mbt",
    "x",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = remove_tool(Workspace::new(tmp), Auto, "{\"path\":\"gone.mbt\"}")
  assert_eq(ok, "removed gone.mbt")
  let raised = try {
    ignore(remove_tool(Workspace::new(tmp), Auto, "{\"path\":\"../outside\"}"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "write_file_tool creates and overwrites files" {
  let tmp = @fs.tmpdir(prefix="moonsage-write-test-")
  let ok = write_file_tool(
    Workspace::new(tmp),
    Auto,
    "{\"path\":\"new.mbt\",\"content\":\"pub fn x() {}\"}",
  )
  assert_eq(ok, "wrote new.mbt")
  assert_true(@fs.read_file(tmp + "/new.mbt").text().contains("pub fn x()"))
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "write_file_tool rejects invalid syntax without writing" {
  let tmp = @fs.tmpdir(prefix="moonsage-write-syncheck-test-")
  let bad = try {
    ignore(
      write_file_tool(
        Workspace::new(tmp),
        Auto,
        "{\"path\":\"bad.mbt\",\"content\":\"fn bad( {\"}",
      ),
    )
    false
  } catch {
    e => e.to_string().contains("语法检查")
  }
  assert_true(bad)
  // 语法门在写盘前执行,目标文件不应被创建。
  let created = try (@fs.kind(tmp + "/bad.mbt") is @fs.FileKind::Regular) catch {
    _ => false
  }
  assert_eq(created, false)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "write_file_tool skips syntax gate for non-source files" {
  let tmp = @fs.tmpdir(prefix="moonsage-write-plain-test-")
  let ok = write_file_tool(
    Workspace::new(tmp),
    Auto,
    "{\"path\":\"notes.txt\",\"content\":\"any text\\n\"}",
  )
  assert_eq(ok, "wrote notes.txt")
  assert_true(@fs.read_file(tmp + "/notes.txt").text().contains("any text"))
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "workspace undo restores overwritten files" {
  let tmp = @fs.tmpdir(prefix="moonsage-undo-overwrite-test-")
  let ws = Workspace::new(tmp)
  let _ = @fs.write_file(
    tmp + "/notes.txt",
    "old text\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = write_file_tool(
    ws,
    Auto,
    "{\"path\":\"notes.txt\",\"content\":\"new text\"}",
  )
  assert_eq(ok, "wrote notes.txt")
  let msg = ws.undo()
  assert_eq(msg, "undid edit to notes.txt")
  assert_eq(@fs.read_file(tmp + "/notes.txt").text(), "old text\n")
  let again = ws.undo()
  assert_eq(again, "nothing to undo")
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "workspace undo removes created files" {
  let tmp = @fs.tmpdir(prefix="moonsage-undo-create-test-")
  let ws = Workspace::new(tmp)
  let ok = write_file_tool(
    ws,
    Auto,
    "{\"path\":\"fresh.txt\",\"content\":\"hello\"}",
  )
  assert_eq(ok, "wrote fresh.txt")
  let msg = ws.undo()
  assert_eq(msg, "undid creation of fresh.txt")
  let exists = try (@fs.kind(tmp + "/fresh.txt") is @fs.FileKind::Regular) catch {
    _ => false
  }
  assert_eq(exists, false)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "workspace undo restores removed files" {
  let tmp = @fs.tmpdir(prefix="moonsage-undo-remove-test-")
  let ws = Workspace::new(tmp)
  let _ = @fs.write_file(
    tmp + "/del.txt",
    "keep me\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = remove_tool(ws, Auto, "{\"path\":\"del.txt\"}")
  assert_eq(ok, "removed del.txt")
  let msg = ws.undo()
  assert_eq(msg, "undid edit to del.txt")
  assert_eq(@fs.read_file(tmp + "/del.txt").text(), "keep me\n")
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "workspace undo restores multi_edit batches per file" {
  let tmp = @fs.tmpdir(prefix="moonsage-undo-multi-test-")
  let ws = Workspace::new(tmp)
  let _ = @fs.write_file(
    tmp + "/a.txt",
    "one\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let _ = @fs.write_file(
    tmp + "/b.txt",
    "two\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = multi_edit_tool(
    ws,
    Auto,
    "{\"edits\":[{\"file\":\"a.txt\",\"old_string\":\"one\",\"new_string\":\"ONE\",\"start_line\":1},{\"file\":\"b.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\",\"start_line\":1}]}",
  )
  assert_true(ok.contains("applied"))
  assert_eq(ws.undo(), "undid edit to b.txt")
  assert_eq(@fs.read_file(tmp + "/b.txt").text(), "two\n")
  assert_eq(ws.undo(), "undid edit to a.txt")
  assert_eq(@fs.read_file(tmp + "/a.txt").text(), "one\n")
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
test "workspace root is shared and mutable" {
  let ws = Workspace::new("C:/work")
  assert_eq(ws.get_root(), "C:/work")
  assert_eq(ws.clone_base(), "C:/work/.moonsage/workspaces")
  ws.set_root("C:/work/.moonsage/workspaces/repo")
  assert_eq(ws.get_root(), "C:/work/.moonsage/workspaces/repo")
}

///|
test "parse_github_url extracts owner and repo" {
  assert_eq(
    parse_github_url("https://github.com/Asterless/MoonPtime.git"),
    Some(("Asterless", "MoonPtime")),
  )
  assert_eq(
    parse_github_url("https://github.com/owner/repo/"),
    Some(("owner", "repo")),
  )
  assert_eq(parse_github_url("https://gitlab.com/owner/repo"), None)
  assert_eq(parse_github_url("https://github.com/owner"), None)
  assert_eq(parse_github_url("not a url"), None)
}

///|
async test "current_repo_owner_name reads git origin" {
  let tmp = @fs.tmpdir(prefix="moonsage-repoinfo-test-")
  let init = @process.collect_output(
    "git",
    ["init"],
    cwd=tmp,
    no_console_window=true,
  )
  let remote = @process.collect_output(
    "git",
    ["remote", "add", "origin", "https://github.com/Asterless/MoonPtime.git"],
    cwd=tmp,
    no_console_window=true,
  )
  if init.0 == 0 && remote.0 == 0 {
    let pair = current_repo_owner_name(tmp)
    assert_eq(pair, ("Asterless", "MoonPtime"))
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "clone_repo_tool clones and switches workspace root" {
  let src = @fs.tmpdir(prefix="moonsage-clone-src-")
  let _ = @fs.write_file(
    src + "/a.mbt",
    "pub fn a() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output(
    "git",
    ["init"],
    cwd=src,
    no_console_window=true,
  )
  let add = @process.collect_output(
    "git",
    ["add", "-A"],
    cwd=src,
    no_console_window=true,
  )
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=src,
    no_console_window=true,
  )
  let ws_base = @fs.tmpdir(prefix="moonsage-clone-ws-")
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    let ws = Workspace::new(ws_base)
    let url = src.replace_all(old="\\", new="/")
    let out = clone_repo_tool(ws, "{\"url\":\"\{url}\"}")
    assert_true(out.contains("cloned"))
    let root = ws.get_root()
    assert_true(root.has_prefix(ws_base))
    assert_true(@fs.read_file(root + "/a.mbt").text().contains("pub fn a()"))
    // 再次调用应复用已有克隆而不是报“已存在”。
    let again = clone_repo_tool(ws, "{\"url\":\"\{url}\"}")
    assert_true(again.contains("reused existing clone"))
    assert_eq(ws.get_root(), root)
  }
  @fs.rmdir(src, recursive=true) catch {
    _ => ()
  }
  @fs.rmdir(ws_base, recursive=true) catch {
    _ => ()
  }
}

///|
#cfg(platform="windows")
fn sleep_cmd_for_timeout_test() -> (String, Array[String]) {
  (
    "powershell",
    ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
  )
}

///|
#cfg(not(platform="windows"))
fn sleep_cmd_for_timeout_test() -> (String, Array[String]) {
  ("sleep", ["30"])
}

///|
async test "run_cmd_with_timeout terminates hung commands" {
  let (cmd, args) = sleep_cmd_for_timeout_test()
  let (exit, err) = run_cmd_with_timeout(args, 1000, cmd~)
  assert_eq(exit, -1)
  assert_true(err.contains("timed out after 1000 ms"))
}

///|
async test "run_cmd_with_timeout returns quick command output" {
  let (exit, err) = run_cmd_with_timeout(["version"], 10000)
  assert_eq(exit, 0)
  assert_eq(err, "")
}

///|
async test "run_cmd_with_timeout reports non-zero exits" {
  let tmp = @fs.tmpdir(prefix="moonsage-cmd-nongit-")
  let (exit, _) = run_cmd_with_timeout(
    ["rev-parse", "--git-dir"],
    5000,
    cwd=tmp,
  )
  assert_true(exit != 0)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "git_has_changes detects tracked, untracked and clean states" {
  let repo = @fs.tmpdir(prefix="moonsage-has-changes-")
  let _ = @fs.write_file(
    repo + "/a.txt",
    "one\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output(
    "git",
    ["init"],
    cwd=repo,
    no_console_window=true,
  )
  let add = @process.collect_output(
    "git",
    ["add", "-A"],
    cwd=repo,
    no_console_window=true,
  )
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=repo,
    no_console_window=true,
  )
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    assert_true(!git_has_changes(repo))
    // 已跟踪文件修改。
    let _ = @fs.write_file(
      repo + "/a.txt",
      "one\ntwo\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    assert_true(git_has_changes(repo))
    // 恢复干净，再新增未跟踪文件。
    let _ = @fs.write_file(
      repo + "/a.txt",
      "one\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let _ = @fs.write_file(
      repo + "/b.txt",
      "new\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    assert_true(git_has_changes(repo))
  }
  @fs.rmdir(repo, recursive=true) catch {
    _ => ()
  }
}

///|
async test "unique_branch_name avoids remote branches" {
  let src = @fs.tmpdir(prefix="moonsage-unique-src-")
  let _ = @fs.write_file(
    src + "/a.mbt",
    "pub fn a() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output(
    "git",
    ["init"],
    cwd=src,
    no_console_window=true,
  )
  let add = @process.collect_output(
    "git",
    ["add", "-A"],
    cwd=src,
    no_console_window=true,
  )
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=src,
    no_console_window=true,
  )
  // 在远程造一个会冲突的分支名。
  let conflict = @process.collect_output(
    "git",
    [
      "-c", "user.name=t", "user.email=t@t", "commit", "--allow-empty", "-m", "conflict",
    ],
    cwd=src,
    no_console_window=true,
  )
  ignore(conflict)
  let conflict_branch = @process.collect_output(
    "git",
    ["branch", "moonsage/fix-x"],
    cwd=src,
    no_console_window=true,
  )
  ignore(conflict_branch)
  let ws_base = @fs.tmpdir(prefix="moonsage-unique-ws-")
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    let ws = Workspace::new(ws_base)
    let url = src.replace_all(old="\\", new="/")
    let out = clone_repo_tool(ws, "{\"url\":\"\{url}\"}")
    assert_true(out.contains("cloned"))
    let root = ws.get_root()
    let name = unique_branch_name(root, "moonsage/fix-x")
    assert_eq(name, "moonsage/fix-x-2")
    let current = git_text(["branch", "--show-current"], root)
    assert_true(current != "")
    assert_eq(remote_default_branch(root, current), current)
  }
  @fs.rmdir(src, recursive=true) catch {
    _ => ()
  }
  @fs.rmdir(ws_base, recursive=true) catch {
    _ => ()
  }
}
