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
test "write paths reject generated and credential files" {
  assert_true(is_protected_write_path(".git/config"))
  assert_true(is_protected_write_path("src/_build/out.mbt"))
  assert_true(is_protected_write_path("_audit_ws_demo/file.mbt"))
  assert_true(is_protected_write_path("config/.env.production"))
  assert_true(!is_protected_write_path("src/main.mbt"))
  assert_true(!is_protected_write_path(".github/workflows/check.yml"))
}

///|
async test "write tools reject protected paths" {
  let tmp = @fs.tmpdir(prefix="moonsage-write-protected-")
  let ws = Workspace::new(tmp)
  for rel in [".env", ".git/config", "target/out.txt"] {
    let rejected = try {
      ignore(
        write_file_tool(
          ws,
          Auto,
          "{\"path\":\"\{rel}\",\"content\":\"secret\"}",
        ),
      )
      false
    } catch {
      error => error.to_string().contains("protected")
    }
    assert_true(rejected)
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
#cfg(not(platform="windows"))
async test "write tools reject symbolic link components" {
  let tmp = @fs.tmpdir(prefix="moonsage-write-symlink-")
  let outside = @fs.tmpdir(prefix="moonsage-write-outside-")
  let linked = tmp + "/linked"
  let (exit, _, _) = @process.collect_output(
    "ln",
    ["-s", outside, linked],
    no_console_window=true,
  )
  if exit == 0 {
    let rejected = try {
      ignore(
        write_file_tool(
          Workspace::new(tmp),
          Auto,
          "{\"path\":\"linked/out.txt\",\"content\":\"outside\"}",
        ),
      )
      false
    } catch {
      error => error.to_string().contains("symbolic")
    }
    assert_true(rejected)
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
  @fs.rmdir(outside, recursive=true) catch {
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
test "publish branch names reject options and ref syntax" {
  assert_true(valid_branch_name("moonsage/mode1/owner-repo-run"))
  assert_true(valid_branch_name("moonsage/fix-repo-2"))
  assert_true(!valid_branch_name("--upload-pack=evil"))
  assert_true(!valid_branch_name("moonsage//bad"))
  assert_true(!valid_branch_name("moonsage/../main"))
  assert_true(!valid_branch_name("refs/x.lock"))
  assert_true(!valid_branch_name("bad branch"))
}

///|
test "publish branch detection supports audit and mode 1 retries" {
  assert_true(is_moonsage_publish_branch("moonsage/fix-parser"))
  assert_true(
    is_moonsage_publish_branch("moonsage/mode1/moonbitlang-core-batch-1"),
  )
  assert_true(!is_moonsage_publish_branch("main"))
  assert_true(!is_moonsage_publish_branch("feature/moonsage"))
}

///|
async test "stage_changed_paths excludes ignored files" {
  let repo = @fs.tmpdir(prefix="moonsage-stage-safe-")
  let _ = @fs.write_file(
    repo + "/a.txt",
    "one\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output("git", ["init"], cwd=repo, no_console_window=true)
  let add = @process.collect_output("git", ["add", "a.txt"], cwd=repo, no_console_window=true)
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=repo,
    no_console_window=true,
  )
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    let _ = @fs.write_file(
      repo + "/a.txt",
      "two\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let paths = stage_changed_paths(repo)
    assert_eq(paths, ["a.txt"])
    let staged = git_text(["diff", "--cached", "--name-only"], repo)
    assert_eq(staged.trim(), "a.txt")
  }
  @fs.rmdir(repo, recursive=true) catch {
    _ => ()
  }
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
    assert_eq(remote_default_branch(root, current), current.trim().to_owned())
  }
  @fs.rmdir(src, recursive=true) catch {
    _ => ()
  }
  @fs.rmdir(ws_base, recursive=true) catch {
    _ => ()
  }
}

///|
test "publish command environments isolate repository credentials" {
  let repository = repository_command_environment()
  assert_eq(repository["GIT_TERMINAL_PROMPT"], "0")
  assert_eq(repository["GIT_LFS_SKIP_SMUDGE"], "1")
  assert_true(repository.get("MOONSAGE_API_KEY") is None)
  assert_true(repository.get("GH_TOKEN") is None)
  assert_true(repository.get("GITHUB_TOKEN") is None)
  assert_true(repository.get("SSH_AUTH_SOCK") is None)
  let github = github_command_environment()
  assert_true(github.get("MOONSAGE_API_KEY") is None)
  assert_true(github.get("SSH_AUTH_SOCK") is None)
  let read_args = secure_git_args(["status", "--short"])
  assert_true(read_args.contains("credential.helper="))
  assert_true(read_args.contains("submodule.recurse=false"))
  assert_true(!read_args.any(fn(arg) {
    arg.contains("gh auth git-credential")
  }))
  let push_args = secure_git_args(
    ["push", "origin", "HEAD:refs/heads/x"],
    github_auth=true,
  )
  assert_true(push_args.any(fn(arg) {
    arg.contains("gh auth git-credential")
  }))
}

///|
test "publish URL path and PR metadata validation is strict" {
  assert_true(canonical_github_url_matches(
    "https://github.com/Owner/Repo.git",
    "owner",
    "repo",
  ))
  assert_true(!canonical_github_url_matches(
    "git@github.com:owner/repo.git",
    "owner",
    "repo",
  ))
  assert_true(!canonical_github_url_matches(
    "https://github.com/owner/repo/tree/main",
    "owner",
    "repo",
  ))
  assert_eq(
    validated_pr_record(
      "https://github.com/o/r/pull/12\tfalse\tmain\tmode1\to",
      "o",
      "r",
      "o",
      "mode1",
      "main",
    ),
    Some("https://github.com/o/r/pull/12"),
  )
  let draft_rejected = try {
    ignore(
      validated_pr_record(
        "https://github.com/o/r/pull/12\ttrue\tmain\tmode1\to",
        "o",
        "r",
        "o",
        "mode1",
        "main",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(draft_rejected)
}

///|
test "publish path and diff classifiers reject unsafe values" {
  assert_eq(
    nul_separated_paths("src/a.mbt\u{0000}README.md\u{0000}"),
    ["src/a.mbt", "README.md"],
  )
  assert_true(valid_repo_relative_path("src/a.mbt"))
  assert_true(!valid_repo_relative_path("../outside"))
  assert_true(!valid_repo_relative_path("src\\outside"))
  assert_true(!valid_repo_relative_path("bad\nname"))
  assert_true(raw_diff_has_symlink_mode(
    ":100644 120000 abc def M\u{0000}link\u{0000}",
  ))
  assert_true(raw_diff_has_symlink_mode(
    ":120000 000000 abc def D\u{0000}link\u{0000}",
  ))
  assert_true(numstat_has_binary("-\t-\timage.bin\u{0000}"))
  assert_true(!numstat_has_binary("2\t1\tsrc/a.mbt\u{0000}"))
  assert_true(valid_git_revision("0123456789abcdef0123456789abcdef01234567"))
  assert_true(!valid_git_revision("not-a-revision"))
}

///|
async test "verified changed-file allowlist must match before staging" {
  let repo = @fs.tmpdir(prefix="moonsage-verified-paths-")
  let _ = @fs.write_file(
    repo + "/a.txt",
    "one\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output("git", ["init"], cwd=repo, no_console_window=true)
  let add = @process.collect_output("git", ["add", "a.txt"], cwd=repo, no_console_window=true)
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=repo,
    no_console_window=true,
  )
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    let _ = @fs.write_file(
      repo + "/a.txt",
      "two\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let _ = @fs.write_file(
      repo + "/b.txt",
      "new\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let rejected = try {
      ignore(stage_changed_paths(repo, verified_paths=["a.txt"]))
      false
    } catch {
      error => error.to_string().contains("allowlist")
    }
    assert_true(rejected)
    assert_eq(git_text(["diff", "--cached", "--name-only"], repo).trim(), "")
    let staged = stage_changed_paths(
      repo,
      verified_paths=["b.txt", "a.txt"],
    )
    assert_eq(staged, ["a.txt", "b.txt"])
  }
  @fs.rmdir(repo, recursive=true) catch {
    _ => ()
  }
}

///|
async test "publisher rejects binary changes before staging" {
  let repo = @fs.tmpdir(prefix="moonsage-binary-publish-")
  let _ = @fs.write_file(
    repo + "/blob.bin",
    "text\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output("git", ["init"], cwd=repo, no_console_window=true)
  let add = @process.collect_output("git", ["add", "blob.bin"], cwd=repo, no_console_window=true)
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=repo,
    no_console_window=true,
  )
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 {
    let _ = @fs.write_file(
      repo + "/blob.bin",
      b"\x00\x01binary",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let rejected = try {
      ignore(stage_changed_paths(repo, verified_paths=["blob.bin"]))
      false
    } catch {
      error => error.to_string().contains("binary")
    }
    assert_true(rejected)
    assert_eq(git_text(["diff", "--cached", "--name-only"], repo).trim(), "")
  }
  @fs.rmdir(repo, recursive=true) catch {
    _ => ()
  }
}

///|
async test "publisher rejects staged git symlink mode" {
  let repo = @fs.tmpdir(prefix="moonsage-symlink-mode-")
  let _ = @fs.write_file(
    repo + "/target.txt",
    "target\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let init = @process.collect_output("git", ["init"], cwd=repo, no_console_window=true)
  let add = @process.collect_output("git", ["add", "target.txt"], cwd=repo, no_console_window=true)
  let commit = @process.collect_output(
    "git",
    ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"],
    cwd=repo,
    no_console_window=true,
  )
  let hash = @process.collect_output(
    "git",
    ["hash-object", "target.txt"],
    cwd=repo,
    no_console_window=true,
  )
  if init.0 == 0 && add.0 == 0 && commit.0 == 0 && hash.0 == 0 {
    let revision = (hash.1.text() catch { _ => "" }).trim().to_owned()
    let update = @process.collect_output(
      "git",
      ["update-index", "--add", "--cacheinfo", "120000", revision, "link"],
      cwd=repo,
      no_console_window=true,
    )
    if update.0 == 0 {
      let rejected = try {
        validate_changed_file_kinds(repo, ["link"])
        false
      } catch {
        error => error.to_string().contains("symbolic-link")
      }
      assert_true(rejected)
    }
  }
  @fs.rmdir(repo, recursive=true) catch {
    _ => ()
  }
}

///|
async test "publisher detects symlink or junction path components when supported" {
  let root = @fs.tmpdir(prefix="moonsage-link-tree-")
  let real = root + "/real"
  @fs.mkdir(real)
  let _ = @fs.write_file(
    real + "/a.txt",
    "a",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let linked = try {
    @fs.symlink(target=real, root + "/linked")
    true
  } catch {
    _ => false
  }
  if linked {
    assert_true(path_tree_has_link_or_special(root, "linked/a.txt"))
  }
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
