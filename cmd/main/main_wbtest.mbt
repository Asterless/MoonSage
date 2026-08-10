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
  let line = engine_event_json(
    @agent.ToolFinished({
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
    engine_event_json(@agent.Error("missing API key")).stringify(),
    "{\"type\":\"error\",\"message\":\"missing API key\"}",
  )
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
