///|
async test "loader labels and combines AGENTS before CLAUDE" {
  let root = @fs.tmpdir(prefix="moonsage-project-combine-test-")
  @fs.write_file(
    root + "/AGENTS.md",
    "agent rules",
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    root + "/CLAUDE.md",
    "claude rules",
    create_mode=CreateOrTruncate,
  )
  let instructions = load_project_instructions(root)
  assert_eq(
    instructions, "\n\n<ProjectInstructions source=\"AGENTS.md\">\nagent rules\n</ProjectInstructions>\n\n<ProjectInstructions source=\"CLAUDE.md\">\nclaude rules\n</ProjectInstructions>",
  )
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "loader bounds each instruction source independently" {
  let root = @fs.tmpdir(prefix="moonsage-project-bounds-test-")
  let agents = "a".repeat(max_project_instruction_bytes + 1)
  let claude = "c".repeat(max_project_instruction_bytes + 1)
  @fs.write_file(root + "/AGENTS.md", agents, create_mode=CreateOrTruncate)
  @fs.write_file(root + "/CLAUDE.md", claude, create_mode=CreateOrTruncate)
  let instructions = load_project_instructions(root)
  assert_true(
    instructions.contains(
      "a".repeat(max_project_instruction_bytes) +
      "\n... [project instructions truncated]",
    ),
  )
  assert_true(!instructions.contains(agents))
  assert_true(
    instructions.contains(
      "c".repeat(max_project_instruction_bytes) +
      "\n... [project instructions truncated]",
    ),
  )
  assert_true(!instructions.contains(claude))
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "loader tolerates one missing instruction file" {
  let root = @fs.tmpdir(prefix="moonsage-project-partial-test-")
  @fs.write_file(
    root + "/CLAUDE.md",
    "claude only",
    create_mode=CreateOrTruncate,
  )
  assert_eq(
    load_project_instructions(root),
    "\n\n<ProjectInstructions source=\"CLAUDE.md\">\nclaude only\n</ProjectInstructions>",
  )
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "loader returns empty when instruction files are missing" {
  let root = @fs.tmpdir(prefix="moonsage-project-empty-test-")
  assert_eq(load_project_instructions(root), "")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
