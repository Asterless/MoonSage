///|
test "workspace permission strings normalize conservatively" {
  assert_true(workspace_permission_from_string("read-only") is ReadOnly)
  assert_true(workspace_permission_from_string("RO") is ReadOnly)
  assert_true(workspace_permission_from_string("full-auto") is FullAuto)
  assert_true(workspace_permission_from_string("unknown") is ControlledWrite)
  assert_eq(workspace_permission_to_string(ReadOnly), "read-only")
  assert_eq(workspace_permission_to_string(ControlledWrite), "controlled-write")
  assert_eq(workspace_permission_to_string(FullAuto), "full-auto")
}

///|
test "workspace agent exposes only safe tools in read-only mode" {
  let agent = workspace_agent("/tmp/moonsage-workspace", ReadOnly, "")
  let names = agent.tools.map(fn(tool) { tool.schema.name })
  assert_true(names.contains("list_project_files"))
  assert_true(names.contains("grep_files"))
  assert_true(names.contains("read_file"))
  assert_true(names.contains("git_diff"))
  assert_true(!names.contains("run_moon"))
  assert_true(!names.contains("write_file"))
  assert_true(!names.contains("multi_edit"))
}

///|
test "workspace agent adds controlled and automatic edit tools" {
  let controlled = workspace_agent(
    "/tmp/moonsage-workspace",
    ControlledWrite,
    "",
  )
  let automatic = workspace_agent("/tmp/moonsage-workspace", FullAuto, "")
  let controlled_names = controlled.tools.map(fn(tool) { tool.schema.name })
  let automatic_names = automatic.tools.map(fn(tool) { tool.schema.name })
  for name in ["write_file", "multi_edit", "remove"] {
    assert_true(controlled_names.contains(name))
    assert_true(automatic_names.contains(name))
  }
  assert_true(controlled.system_prompt.contains("controlled-write"))
  assert_true(automatic.system_prompt.contains("full-auto"))
}
