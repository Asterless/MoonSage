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
  let agent = chat_agent([], "C:/work")
  assert_eq(agent.tools.length(), 8)
  let names = agent.tools.map(fn(t) { t.schema.name })
  assert_true(names.contains("search_modules"))
  assert_true(names.contains("get_module_manifest"))
  assert_true(names.contains("get_module_index"))
  assert_true(names.contains("get_package_docs"))
  assert_true(names.contains("list_project_files"))
  assert_true(names.contains("read_file"))
  assert_true(names.contains("run_moon"))
  assert_true(names.contains("git_diff"))
  assert_true(!names.contains("write_file"))
  assert_eq(agent.max_tool_calls, 12)
  assert_eq(agent.max_rounds, 6)
  assert_true(agent.max_tokens > 0)
}
