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
async test "multi_edit_tool applies edits atomically with syntax gate" {
  let tmp = @fs.tmpdir(prefix="moonsage-edit-test-")
  let _ = @fs.write_file(
    tmp + "/a.mbt",
    "pub fn old() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ok = multi_edit_tool(
    tmp,
    Auto,
    "{\"edits\":[{\"file\":\"a.mbt\",\"old_string\":\"pub fn old() {}\",\"new_string\":\"pub fn new() {}\",\"start_line\":1}]}",
  )
  assert_true(ok.contains("applied"))
  assert_true(@fs.read_file(tmp + "/a.mbt").text().contains("pub fn new()"))
  // 语法门拒绝：修改后无法解析，整批不落盘。
  let bad = try {
    ignore(
      multi_edit_tool(
        tmp,
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
  let ok = remove_tool(tmp, Auto, "{\"path\":\"gone.mbt\"}")
  assert_eq(ok, "removed gone.mbt")
  let raised = try {
    ignore(remove_tool(tmp, Auto, "{\"path\":\"../outside\"}"))
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
    tmp,
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
  }
  @fs.rmdir(src, recursive=true) catch {
    _ => ()
  }
  @fs.rmdir(ws_base, recursive=true) catch {
    _ => ()
  }
}
