///|
test "parse_github_repo extracts owner and repo" {
  assert_eq(
    parse_github_repo("https://github.com/moonbit-community/cmark.mbt"),
    Some(("moonbit-community", "cmark.mbt")),
  )
  assert_eq(
    parse_github_repo("https://github.com/owner/repo.git"),
    Some(("owner", "repo")),
  )
  assert_eq(
    parse_github_repo("https://github.com/owner/repo/"),
    Some(("owner", "repo")),
  )
  assert_eq(parse_github_repo("https://gitlab.com/owner/repo"), None)
  assert_eq(parse_github_repo("not a url"), None)
}

///|
fn manifest_repo_checked(manifest : String) -> String {
  manifest_repository(manifest) catch {
    _ => ""
  }
}

///|
test "manifest_repository extracts metadata.repository" {
  let manifest = "{\"metadata\":{\"repository\":\"https://github.com/x/y\"}}"
  assert_eq(manifest_repo_checked(manifest), "https://github.com/x/y")
  assert_eq(manifest_repo_checked("{}"), "")
}

///|
test "parse_int_or falls back to default" {
  assert_eq(parse_int_or("42", 0), 42)
  assert_eq(parse_int_or("abc", 7), 7)
}

///|
test "relative_to_root strips project root prefix" {
  assert_eq(relative_to_root("C:/p", "C:/p/src/a.mbt"), "src/a.mbt")
  assert_eq(relative_to_root("C:/p", "C:/other"), "C:/other")
}

///|
test "truncate_output keeps long output bounded" {
  assert_eq(truncate_output("short", 100), "short")
  let long = truncate_output("a".repeat(20), 10)
  assert_true(long.contains("truncated"))
  assert_true(!long.contains("a".repeat(20)))
}

///|
test "safe_project_path allows relative files and blocks traversal" {
  let ctx : AuditContext = {
    project_dir: "C:/work/proj",
    fix: false,
    confirm: ConfirmDiff,
  }
  assert_eq(safe_project_path(ctx, "src/a.mbt"), "C:/work/proj/src/a.mbt")
  assert_eq(safe_project_path(ctx, "moon.mod"), "C:/work/proj/moon.mod")
  let blocked = try {
    ignore(safe_project_path(ctx, "../evil"))
    false
  } catch {
    _ => true
  }
  assert_true(blocked)
  let absolute = try {
    ignore(safe_project_path(ctx, "/etc/passwd"))
    false
  } catch {
    _ => true
  }
  assert_true(absolute)
}

///|
test "audit tool schemas include write_file only in fix mode" {
  let read_only = audit_tool_schemas(false)
  assert_eq(read_only.length(), 4)
  assert_true(!read_only.map(fn(t) { t.name }).contains("write_file"))
  let fix = audit_tool_schemas(true)
  assert_eq(fix.length(), 5)
  assert_true(fix.map(fn(t) { t.name }).contains("write_file"))
}

///|
test "parse_audit_options handles flags" {
  let opts = parse_audit_options([
    "owner/mod", "--fix", "--confirm", "yes", "--workspace", "C:/tmp/w", "--max-calls",
    "50",
  ]) catch {
    _ => audit_default_options()
  }
  assert_eq(opts.name, "owner/mod")
  assert_true(opts.fix)
  assert_true(opts.confirm is ConfirmYes)
  assert_eq(opts.workspace, "C:/tmp/w")
  assert_eq(opts.max_calls, 50)
  let bad = try {
    ignore(parse_audit_options(["owner/mod", "--confirm", "bogus"]))
    false
  } catch {
    _ => true
  }
  assert_true(bad)
}
