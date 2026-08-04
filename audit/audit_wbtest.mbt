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
  assert_eq(
    parse_github_repo("https://github.com/owner/repo/tree/main"),
    Some(("owner", "repo")),
  )
  assert_eq(
    parse_github_repo("https://github.com/owner/repo.git/"),
    Some(("owner", "repo")),
  )
  // http is rejected: only https GitHub URLs are supported
  assert_eq(parse_github_repo("http://github.com/owner/repo"), None)
  assert_eq(parse_github_repo("https://gitlab.com/owner/repo"), None)
  assert_eq(parse_github_repo("https://github.com/owner"), None)
  assert_eq(parse_github_repo("https://github.com/"), None)
  assert_eq(parse_github_repo("not a url"), None)
  assert_eq(parse_github_repo(""), None)
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
  // missing metadata entirely
  assert_eq(manifest_repo_checked("{}"), "")
  // metadata without repository
  assert_eq(manifest_repo_checked("{\"metadata\":{\"name\":\"x\"}}"), "")
  // malformed JSON
  assert_eq(manifest_repo_checked("not json"), "")
  // metadata is not an object
  assert_eq(manifest_repo_checked("{\"metadata\":\"oops\"}"), "")
}

///|
test "parse_int_or falls back to default" {
  assert_eq(parse_int_or("42", 0), 42)
  assert_eq(parse_int_or("0", 9), 0)
  assert_eq(parse_int_or("-3", 9), -3)
  assert_eq(parse_int_or("  7 ", 1), 1)
  assert_eq(parse_int_or("abc", 7), 7)
  assert_eq(parse_int_or("", 2), 2)
}

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
  let nested = try {
    ignore(safe_project_path(ctx, "src/../../evil"))
    false
  } catch {
    _ => true
  }
  assert_true(nested)
  let absolute = try {
    ignore(safe_project_path(ctx, "/etc/passwd"))
    false
  } catch {
    _ => true
  }
  assert_true(absolute)
  let win_abs = try {
    ignore(safe_project_path(ctx, "C:\\evil"))
    false
  } catch {
    _ => true
  }
  assert_true(win_abs)
  let drive = try {
    ignore(safe_project_path(ctx, "C:/evil"))
    false
  } catch {
    _ => true
  }
  assert_true(drive)
  let empty = try {
    ignore(safe_project_path(ctx, ""))
    false
  } catch {
    _ => true
  }
  assert_true(empty)
}

///|
test "audit tools include write_file only in fix mode" {
  let ro_ctx : AuditContext = {
    project_dir: "C:/p",
    fix: false,
    confirm: ConfirmDiff,
  }
  let read_only = audit_tools(ro_ctx)
  assert_eq(read_only.length(), 4)
  let names = read_only.map(fn(t) { t.schema.name })
  assert_eq(names, ["list_project_files", "read_file", "run_moon", "git_diff"])
  assert_true(!names.contains("write_file"))
  let fix_ctx : AuditContext = {
    project_dir: "C:/p",
    fix: true,
    confirm: ConfirmDiff,
  }
  let fix = audit_tools(fix_ctx)
  assert_eq(fix.length(), 5)
  assert_true(fix.map(fn(t) { t.schema.name }).contains("write_file"))
  // git_diff tool is always present
  let always = fix.filter(fn(t) { t.schema.name == "git_diff" })
  assert_eq(always.length(), 1)
}

///|
test "parse_audit_options defaults and flags" {
  let defaults = parse_audit_options(["owner/mod"]) catch {
    _ => audit_default_options()
  }
  assert_eq(defaults.name, "owner/mod")
  assert_true(!defaults.fix)
  assert_true(defaults.confirm is ConfirmDiff)
  assert_eq(defaults.workspace, "")
  assert_eq(defaults.max_calls, 30)
  assert_eq(defaults.max_rounds, 8)

  let opts = parse_audit_options([
    "owner/mod", "--fix", "--confirm", "prompt", "--workspace", "C:/tmp/w", "--max-calls",
    "50",
  ]) catch {
    _ => audit_default_options()
  }
  assert_eq(opts.name, "owner/mod")
  assert_true(opts.fix)
  assert_true(opts.confirm is ConfirmPrompt)
  assert_eq(opts.workspace, "C:/tmp/w")
  assert_eq(opts.max_calls, 50)

  let yes = parse_audit_options(["owner/mod", "--confirm", "yes"]) catch {
    _ => audit_default_options()
  }
  assert_true(yes.confirm is ConfirmYes)

  // invalid max-calls falls back to the default instead of failing
  let bad_count = parse_audit_options(["owner/mod", "--max-calls", "abc"]) catch {
    _ => audit_default_options()
  }
  assert_eq(bad_count.max_calls, 30)
}

///|
test "parse_audit_options rejects bad input" {
  let raised = try {
    ignore(parse_audit_options([]))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  let bad_confirm = try {
    ignore(parse_audit_options(["owner/mod", "--confirm", "bogus"]))
    false
  } catch {
    _ => true
  }
  assert_true(bad_confirm)
  let missing_confirm = try {
    ignore(parse_audit_options(["owner/mod", "--confirm"]))
    false
  } catch {
    _ => true
  }
  assert_true(missing_confirm)
  let missing_workspace = try {
    ignore(parse_audit_options(["owner/mod", "--workspace"]))
    false
  } catch {
    _ => true
  }
  assert_true(missing_workspace)
  let unknown_flag = try {
    ignore(parse_audit_options(["owner/mod", "--wat"]))
    false
  } catch {
    _ => true
  }
  assert_true(unknown_flag)
}
