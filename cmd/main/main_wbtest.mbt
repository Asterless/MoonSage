///|
test "join_query joins arguments from the start index" {
  assert_eq(join_query(["moon", "run", "ask", "a", "b"], 2), "ask a b")
  assert_eq(join_query(["search", "json"], 0), "search json")
}

///|
test "cli parses subcommands" {
  let root = root_command()
  let chat = root.parse(argv=["chat"], env=Map([]))
  assert_true(chat.subcommand is Some(("chat", _)))
  let tui = root.parse(argv=["tui"], env=Map([]))
  assert_true(tui.subcommand is Some(("tui", _)))
  let search = root.parse(argv=["search", "http", "client"], env=Map([]))
  guard search.subcommand is Some(("search", sm)) else {
    assert_true(false)
    return
  }
  assert_eq(join_values(sm, "keywords"), "http client")
  let ask = root.parse(argv=["ask", "推荐一个库"], env=Map([]))
  guard ask.subcommand is Some(("ask", am)) else {
    assert_true(false)
    return
  }
  assert_eq(join_values(am, "question"), "推荐一个库")
  let task = root.parse(
    argv=[
      "task", "--workspace", "D:/work/demo", "--permission", "read-only", "--stream-json",
      "检查文件",
    ],
    env=Map([]),
  )
  guard task.subcommand is Some(("task", tm)) else {
    assert_true(false)
    return
  }
  assert_eq(task_workspace(tm), "D:/work/demo")
  assert_true(task_permission(tm) is @agent.WorkspacePermission::ReadOnly)
  assert_true(flag_of(tm, "stream-json"))
  assert_eq(join_values(tm, "goal"), "检查文件")
}

///|
test "ask accepts stream-json and serializes structured tool events" {
  let root = root_command()
  let parsed = root.parse(
    argv=["ask", "--stream-json", "find", "http"],
    env=Map([]),
  )
  guard parsed.subcommand is Some(("ask", ask)) else {
    assert_true(false)
    return
  }
  assert_true(flag_of(ask, "stream-json"))
  assert_eq(join_values(ask, "question"), "find http")
  let line = @protocol.event_to_json(
    ToolFinished({
      round: 2,
      call_id: "call_1",
      name: "run_moon",
      status: "ok",
      result: "{\"exit_code\":0}",
    }),
  ).stringify()
  assert_eq(
    line, "{\"type\":\"tool_finished\",\"round\":2,\"call_id\":\"call_1\",\"name\":\"run_moon\",\"status\":\"ok\",\"result\":\"{\\\"exit_code\\\":0}\"}",
  )
  assert_eq(
    @protocol.event_to_json(Error("missing API key")).stringify(),
    "{\"type\":\"error\",\"message\":\"missing API key\"}",
  )
}

///|
async test "ask reads a UTF-8 input file" {
  let root = @fs.tmpdir(prefix="moonsage-ask-input-")
  let path = root + "/prompt.txt"
  @fs.write_file(
    path,
    "检查 async 包的 API\n并给出建议",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let matches = root_command().parse(argv=["ask", "--input-file", path])
  guard matches.subcommand is Some(("ask", ask)) else {
    fail("ask subcommand was not parsed")
  }
  assert_eq(ask_question(ask), "检查 async 包的 API\n并给出建议")
  @fs.rmdir(root, recursive=true)
}

///|
async test "ask decodes externally written UTF-8 bytes" {
  let root = @fs.tmpdir(prefix="moonsage-ask-utf8-")
  let path = root + "/prompt.txt"
  @fs.write_file(
    path,
    b"\xe5\x8f\xaa\xe5\x9b\x9e\xe5\xa4\x8d\xef\xbc\x9aAPI\xe9\x93\xbe\xe8\xb7\xaf\xe6\x88\x90\xe5\x8a\x9f",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let matches = root_command().parse(argv=["ask", "--input-file", path])
  guard matches.subcommand is Some(("ask", ask)) else {
    fail("ask subcommand was not parsed")
  }
  assert_eq(ask_question(ask), "只回复：API链路成功")
  @fs.rmdir(root, recursive=true)
}

///|
test "audit args reconstruct raw arguments" {
  let root = root_command()
  let parsed = root.parse(
    argv=["audit", "owner/mod", "--fix", "--max-calls", "40"],
    env=Map([]),
  )
  guard parsed.subcommand is Some(("audit", m)) else {
    assert_true(false)
    return
  }
  assert_eq(audit_args(m), ["owner/mod", "--fix", "--max-calls", "40"])
  let clean = root.parse(argv=["audit", "--clean"], env=Map([]))
  guard clean.subcommand is Some(("audit", cm)) else {
    assert_true(false)
    return
  }
  assert_eq(audit_args(cm), ["--clean"])
}

///|
test "mode 1 is normalized to the batch-audit parser path" {
  assert_eq(
    normalize_mode_one_args([
      "moonsage", "mode", "1", "start", "--watch", "--include", "acme/*",
    ]),
    ["moonsage", "batch-audit", "start", "--watch", "--include", "acme/*"],
  )
  assert_eq(normalize_mode_one_args(["moonsage", "mode", "2"]), [
    "moonsage", "mode", "2",
  ])
}

///|
test "batch-audit parser accepts start and control operations" {
  let start = root_command().parse(argv=[
    "batch-audit", "start", "--watch", "--include", "acme/*", "--include", "moonbitlang/*",
    "--concurrency", "4", "--max-prs", "10",
  ])
  guard start.subcommand is Some(("batch-audit", matches)) else {
    fail("batch-audit subcommand was not selected")
  }
  assert_eq(values_of(matches, "operation"), ["start"])
  assert_eq(values_of(matches, "include"), ["acme/*", "moonbitlang/*"])
  assert_true(flag_of(matches, "watch"))
  assert_eq(values_of(matches, "concurrency"), ["4"])

  let retry = root_command().parse(argv=[
    "batch-audit", "retry", "batch-1234", "--item", "acme--parser",
  ])
  guard retry.subcommand is Some(("batch-audit", control)) else {
    fail("batch-audit control command was not selected")
  }
  assert_eq(values_of(control, "operation"), ["retry"])
  assert_eq(values_of(control, "batch"), ["batch-1234"])
  assert_eq(values_of(control, "item"), ["acme--parser"])
}

///|
test "batch-audit parses bounded integers and durations" {
  assert_eq(parse_batch_integer("4", "concurrency", 1, 4), 4)
  assert_eq(parse_batch_duration("20m", "timeout", 1000, 86400000), 1200000)
  assert_eq(
    parse_batch_duration("6h", "interval", 1000, 2_000_000_000),
    21600000,
  )
  try parse_batch_integer("5", "concurrency", 1, 4) catch {
    error => assert_true(error.to_string().contains("between 1 and 4"))
  } noraise {
    _ => fail("out-of-range concurrency must be rejected")
  }
  try parse_batch_duration("forever", "interval", 1000, 2_000_000_000) catch {
    error => assert_true(error.to_string().contains("must use"))
  } noraise {
    _ => fail("invalid duration must be rejected")
  }
}

///|
test "batch-audit config uses mode 1 defaults and repeated filters" {
  let parsed = root_command().parse(argv=[
    "batch-audit", "start", "--include", "acme/*", "--owner", "acme", "--keyword",
    "parser", "--exclude", "*/old", "--concurrency", "3", "--package-timeout", "15m",
  ])
  guard parsed.subcommand is Some(("batch-audit", matches)) else {
    fail("batch-audit subcommand was not selected")
  }
  let config = batch_config_from_matches(matches)
  assert_eq(config.includes, ["acme/*"])
  assert_eq(config.owners, ["acme"])
  assert_eq(config.keywords, ["parser"])
  assert_eq(config.excludes, ["*/old"])
  assert_eq(config.concurrency, 3)
  assert_eq(config.package_timeout_ms, 900000)
  assert_eq(config.max_prs, 10)
  assert_eq(config.max_calls, 80)
}

///|
test "cli accepts --version flag" {
  let root = root_command()
  let parsed = root.parse(argv=["--version"], env=Map([]))
  assert_true(flag_of(parsed, "version"))
  let short = root.parse(argv=["-V"], env=Map([]))
  assert_true(flag_of(short, "version"))
}

///|
test "cli parses chat session options" {
  let root = root_command()
  let parsed = root.parse(
    argv=["chat", "--session", "demo", "--continue"],
    env=Map([]),
  )
  guard parsed.subcommand is Some(("chat", m)) else {
    assert_true(false)
    return
  }
  assert_eq(values_of(m, "session"), ["demo"])
  assert_true(flag_of(m, "continue"))
  let tui = root.parse(
    argv=["tui", "--session", "visual", "--continue"],
    env=Map([]),
  )
  guard tui.subcommand is Some(("tui", tm)) else {
    assert_true(false)
    return
  }
  assert_eq(values_of(tm, "session"), ["visual"])
  assert_true(flag_of(tm, "continue"))
}
