///|
test "relative_to_root strips project root prefix" {
  assert_eq(relative_to_root("C:/p", "C:/p/src/a.mbt"), "src/a.mbt")
  assert_eq(relative_to_root("C:/p", "C:/other"), "C:/other")
  assert_eq(relative_to_root("C:/p", "C:/p"), "C:/p")
  assert_eq(relative_to_root("/root", "/root/moon.mod"), "moon.mod")
}

///|
test "truncate_output keeps long output bounded" {
  assert_eq(truncate_output("short", 100), "short")
  assert_eq(truncate_output("", 10), "")
  let long = truncate_output("a".repeat(20), 10)
  assert_true(long.contains("truncated"))
  assert_true(!long.contains("a".repeat(20)))
}

///|
test "truncate_output preserves the head and tail" {
  let output = truncate_output(
    "first passed line\n" +
    "middle output that can be discarded\n" +
    "last failure summary",
    64,
  )
  assert_true(output.has_prefix("first passed line"))
  assert_true(output.contains("last failure summary"))
  assert_true(output.contains("truncated"))
}

///|
test "truncate_output preserves long single-line output" {
  let output = truncate_output(
    "first-error-" + "x".repeat(200) + "-last-error",
    64,
  )
  assert_true(output.has_prefix("first-error-"))
  assert_true(output.contains("-last-error"))
  assert_true(output.contains("truncated"))
}

///|
test "truncate_output keeps Unicode and CRLF content valid" {
  let output = truncate_output(
    "开始 😊\r\n" + "中间输出\r\n" + "末尾失败汇总",
    64,
  )
  assert_true(output.contains("开始 😊"))
  assert_true(output.contains("末尾失败汇总"))
}

///|
test "local_tools exposes the five read-only tools" {
  let tools = local_tools(@editing.Workspace::new("C:/work/proj"))
  assert_eq(tools.length(), 5)
  let names = tools.map(fn(t) { t.schema.name })
  assert_eq(names, [
    "list_project_files", "grep_files", "read_file", "run_moon", "git_diff",
  ])
}

///|
test "verification commands are fixed and native-only" {
  assert_eq(verification_args("check"), ["check", "--target", "native"])
  assert_eq(verification_args("build"), ["build", "--target", "native"])
  assert_eq(verification_args("test"), ["test", "--target", "native"])
  let rejected = try {
    ignore(verification_args("run"))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "verification tools expose only the constrained runner" {
  let tools = verification_tools(@editing.Workspace::new("."))
  assert_eq(tools.map(fn(tool) { tool.schema.name }), ["run_moon"])
}

///|
test "wildcard_match supports * and ?" {
  assert_true(wildcard_match("*.mbt", "src/main.mbt"))
  assert_true(wildcard_match("src/*.mbt", "src/main.mbt"))
  assert_true(wildcard_match("src/?ain.mbt", "src/main.mbt"))
  assert_true(wildcard_match("*", "anything"))
  assert_true(wildcard_match("", ""))
  assert_eq(wildcard_match("*.mbt", "src/main.txt"), false)
  assert_eq(wildcard_match("src/*.mbt", "lib/main.mbt"), false)
  assert_eq(wildcard_match("a?c", "ac"), false)
  assert_eq(wildcard_match("*.mbt", ""), false)
}

///|
test "workspace ignore policy matches generated entries case-insensitively" {
  assert_true(is_ignored_project_entry(".git"))
  assert_true(is_ignored_project_entry(".MOONCAKES"))
  assert_true(is_ignored_project_entry(".moonsage"))
  assert_true(is_ignored_project_entry(".CACHE"))
  assert_true(is_ignored_project_entry("_build"))
  assert_true(is_ignored_project_entry("_BUILD.BAK"))
  assert_true(is_ignored_project_entry("Node_Modules"))
  assert_true(is_ignored_project_entry("TARGET"))
  assert_true(is_ignored_project_entry("_AUDIT_WS_example"))
  assert_true(is_ignored_project_path("src/.env"))
  assert_true(is_ignored_project_path(".MOONSAGE/state.json"))
  assert_true(is_ignored_project_path("_audit_ws_123/report.md"))
  assert_true(!is_ignored_project_path("src/main.mbt"))
}

///|
async test "list_project_files_tool excludes generated directories and env files" {
  let tmp = @fs.tmpdir(prefix="moonsage-ignore-test-")
  @fs.mkdir(tmp + "/src", recursive=true)
  let _ = @fs.write_file(
    tmp + "/src/main.mbt",
    "pub fn main() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let ignored_directories = [
    ".git", ".mooncakes", ".moonsage", ".cache", "_build", "_build.bak", "node_modules",
    "target", "_audit_ws_example",
  ]
  for directory in ignored_directories {
    @fs.mkdir(tmp + "/" + directory, recursive=true)
    let _ = @fs.write_file(
      tmp + "/" + directory + "/hidden.mbt",
      "let hidden = true\n",
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
  }
  let _ = @fs.write_file(
    tmp + "/.env",
    "SECRET=hidden\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let payload = list_project_files_tool(tmp, "{}")
  let doc = @json.parse(payload)
  guard doc is Object(fields) else { fail("expected object") }
  let files = match fields.get("files") {
    Some(Array(items)) => items
    _ => fail("missing files")
  }
  assert_eq(files.length(), 1)
  assert_eq(files[0].stringify(), "\"src/main.mbt\"")
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "local file tools reject ignored paths" {
  let tmp = @fs.tmpdir(prefix="moonsage-ignore-path-test-")
  let read_blocked = try {
    ignore(read_file_tool(tmp, "{\"path\":\".moonsage/state.json\"}"))
    false
  } catch {
    _ => true
  }
  let grep_blocked = try {
    ignore(grep_files_tool(tmp, "{\"pattern\":\"secret\",\"path\":\"_build\"}"))
    false
  } catch {
    _ => true
  }
  let list_blocked = try {
    ignore(list_project_files_tool(tmp, "{\"path\":\"node_modules\"}"))
    false
  } catch {
    _ => true
  }
  assert_true(read_blocked)
  assert_true(grep_blocked)
  assert_true(list_blocked)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "list_project_files_tool filters by pattern and reports truncation" {
  let tmp = @fs.tmpdir(prefix="moonsage-list-test-")
  let _ = @fs.write_file(
    tmp + "/a.mbt",
    "pub fn a() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let _ = @fs.write_file(
    tmp + "/b.txt",
    "hello\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let _ = @fs.write_file(
    tmp + "/c.mbt",
    "pub fn c() {}\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let payload = list_project_files_tool(tmp, "{\"pattern\":\"*.mbt\"}")
  let doc = @json.parse(payload)
  guard doc is Object(fields) else { fail("expected object") }
  let files = match fields.get("files") {
    Some(Array(items)) => items
    _ => fail("missing files")
  }
  assert_eq(files.length(), 2)
  let truncated = match fields.get("truncated") {
    Some(True) => true
    Some(False) => false
    _ => fail("missing truncated")
  }
  assert_eq(truncated, false)
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "grep_files_tool returns path:line matches" {
  let tmp = @fs.tmpdir(prefix="moonsage-grep-test-")
  let _ = @fs.write_file(
    tmp + "/a.mbt",
    "pub fn alpha() {}\n// alpha note\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let _ = @fs.write_file(
    tmp + "/b.txt",
    "nothing here\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let payload = grep_files_tool(tmp, "{\"pattern\":\"alpha\"}")
  let doc = @json.parse(payload)
  guard doc is Object(fields) else { fail("expected object") }
  let matches = match fields.get("matches") {
    Some(Array(items)) => items
    _ => fail("missing matches")
  }
  assert_eq(matches.length(), 2)
  assert_true(matches[0].stringify().contains("a.mbt:1: pub fn alpha"))
  assert_true(matches[1].stringify().contains("a.mbt:2: // alpha note"))
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
// A command that sleeps long enough to reliably trigger a timeout.
#cfg(platform="windows")
fn sleep_long_command() -> (String, Array[String]) {
  (
    "powershell",
    ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
  )
}

///|
#cfg(not(platform="windows"))
fn sleep_long_command() -> (String, Array[String]) {
  ("sleep", ["30"])
}

///|
test "command_timeout_json reports the deadline" {
  let payload = command_timeout_json(3000)
  assert_true(payload.contains("timed out after 3000 ms"))
  let doc = @json.parse(payload)
  match doc {
    Object(fields) =>
      match fields.get("exit_code") {
        Some(Number(n, ..)) => assert_eq(n, -1.0)
        _ => fail("exit_code missing")
      }
    _ => fail("expected JSON object")
  }
}

///|
async test "run_command_with_timeout terminates hung commands" {
  let tmp = @fs.tmpdir(prefix="moonsage-timeout-test-")
  let (cmd, args) = sleep_long_command()
  let payload = run_command_with_timeout(cmd, tmp, args, 1000)
  assert_true(payload.contains("timed out after 1000 ms"))
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
async test "run_command_with_timeout returns output for quick commands" {
  let tmp = @fs.tmpdir(prefix="moonsage-runmoon-test-")
  let payload = run_command_with_timeout("moon", tmp, ["version"], 10000)
  let doc = @json.parse(payload)
  match doc {
    Object(fields) =>
      match fields.get("exit_code") {
        Some(Number(n, ..)) => assert_eq(n, 0.0)
        _ => fail("exit_code missing")
      }
    _ => fail("expected JSON object")
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}
