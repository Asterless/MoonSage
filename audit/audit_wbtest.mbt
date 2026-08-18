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
  assert_eq(parse_github_repo("https://github.com/owner/repo/"), None)
  assert_eq(parse_github_repo("https://github.com/owner/repo/tree/main"), None)
  assert_eq(parse_github_repo("https://github.com/owner/repo.git/"), None)
  assert_eq(parse_github_repo("https://github.com/owner/repo?x=1"), None)
  assert_eq(parse_github_repo("https://github.com/owner/repo#readme"), None)
  // http is rejected: only https GitHub URLs are supported
  assert_eq(parse_github_repo("http://github.com/owner/repo"), None)
  assert_eq(parse_github_repo("https://gitlab.com/owner/repo"), None)
  assert_eq(parse_github_repo("https://github.com/owner"), None)
  assert_eq(parse_github_repo("https://github.com/"), None)
  assert_eq(parse_github_repo("not a url"), None)
  assert_eq(parse_github_repo(""), None)
}

///|
test "audit clone command disables ambient credentials hooks and submodules" {
  let args = secured_clone_args(
    "https://github.com/owner/repo.git",
    "C:/tmp/repo",
    branch="main",
  )
  assert_eq(args[0], "-c")
  assert_true(args.contains("credential.helper="))
  assert_true(args.contains("submodule.recurse=false"))
  assert_true(args.contains("--no-recurse-submodules"))
  assert_true(args.contains("--no-tags"))
  assert_true(args.contains("--single-branch"))
  assert_true(args.contains("main"))
  let environment = audit_repo_environment()
  assert_eq(environment["GIT_TERMINAL_PROMPT"], "0")
  assert_eq(environment["GIT_LFS_SKIP_SMUDGE"], "1")
  assert_true(environment.get("MOONSAGE_API_KEY") is None)
  assert_true(environment.get("GH_TOKEN") is None)
  assert_true(environment.get("GITHUB_TOKEN") is None)
  assert_true(environment.get("SSH_AUTH_SOCK") is None)
}

///|
test "parse_github_repo rejects traversal or invalid components" {
  assert_eq(parse_github_repo("https://github.com/owner/.."), None)
  assert_eq(parse_github_repo("https://github.com/.."), None)
  assert_eq(parse_github_repo("https://github.com/o wner/repo"), None)
  assert_eq(parse_github_repo("https://github.com/owner/..%2e"), None)
  assert_eq(parse_github_repo("https://github.com/owner/repo\\x"), None)
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
test "audit tools include write_file only in fix mode" {
  let ro_ctx : AuditContext = {
    project_dir: "C:/p",
    fix: false,
    confirm: ConfirmDiff,
  }
  let read_only = audit_tools(ro_ctx)
  assert_eq(read_only.length(), 5)
  let names = read_only.map(fn(t) { t.schema.name })
  assert_eq(names, [
    "list_project_files", "grep_files", "read_file", "run_moon", "git_diff",
  ])
  assert_true(!names.contains("write_file"))
  let fix_ctx : AuditContext = {
    project_dir: "C:/p",
    fix: true,
    confirm: ConfirmDiff,
  }
  let fix = audit_tools(fix_ctx)
  assert_eq(fix.length(), 8)
  assert_true(fix.map(fn(t) { t.schema.name }).contains("write_file"))
  assert_true(fix.map(fn(t) { t.schema.name }).contains("multi_edit"))
  assert_true(fix.map(fn(t) { t.schema.name }).contains("remove"))
  // git_diff tool is always present
  let always = fix.filter(fn(t) { t.schema.name == "git_diff" })
  assert_eq(always.length(), 1)
}

///|
test "mode 1 audit tools replace arbitrary moon arguments with fixed verification" {
  let ctx : AuditContext = {
    project_dir: "C:/p",
    fix: true,
    confirm: ConfirmYes,
  }
  let tools = audit_tools(ctx, restricted_moon=true)
  assert_eq(tools.length(), 8)
  let moon = tools.filter(fn(tool) { tool.schema.name == "run_moon" })
  assert_eq(moon.length(), 1)
  assert_true(moon[0].schema.description.contains("target is always native"))
  assert_true(tools.map(fn(tool) { tool.schema.name }).contains("write_file"))
  assert_true(!tools.map(fn(tool) { tool.schema.name }).contains("create_pr"))
}

///|
fn audit_answer(
  text : String,
  events : Array[@runtime.EngineEvent],
) -> @runtime.AgentAnswer {
  @runtime.AgentAnswer::new(text, [], events)
}

///|
test "audit evidence rejects a claimed verification with failing exit code" {
  let answer = audit_answer("## 审计报告\n测试通过", [
    @runtime.ToolStarted({
      round: 0,
      call_id: "run-1",
      name: "run_moon",
      arguments: "{\"args\":\"test\"}",
    }),
    @runtime.ToolFinished({
      round: 0,
      call_id: "run-1",
      name: "run_moon",
      status: "ok",
      result: "{\"exit_code\":1,\"stdout\":\"\",\"stderr\":\"failed\"}",
    }),
  ])
  let evidence = build_audit_evidence(None, answer, false)
  assert_true(evidence.verification_ran)
  assert_true(!evidence.verified)
  assert_eq(evidence.conflicts.length(), 1)
  assert_true(evidence.conflicts[0].contains("exit code was 1"))
}

///|
test "audit evidence requires a successful post-fix verification" {
  let answer = audit_answer("## 审计报告", [
    @runtime.ToolStarted({
      round: 0,
      call_id: "write-1",
      name: "write_file",
      arguments: "{\"path\":\"main.mbt\"}",
    }),
    @runtime.ToolFinished({
      round: 0,
      call_id: "write-1",
      name: "write_file",
      status: "ok",
      result: "applied",
    }),
  ])
  let evidence = build_audit_evidence(None, answer, true)
  assert_true(!evidence.verification_ran)
  assert_true(!evidence.verified)
  assert_true(evidence.conflicts[0].contains("No post-fix"))
}

///|
test "audit evidence verifies a successful post-fix moon command" {
  let answer = audit_answer("## 审计报告", [
    @runtime.ToolStarted({
      round: 0,
      call_id: "edit-1",
      name: "multi_edit",
      arguments: "{\"edits\":[]}",
    }),
    @runtime.ToolFinished({
      round: 0,
      call_id: "edit-1",
      name: "multi_edit",
      status: "ok",
      result: "applied",
    }),
    @runtime.ToolStarted({
      round: 1,
      call_id: "run-1",
      name: "run_moon",
      arguments: "{\"args\":\"test\"}",
    }),
    @runtime.ToolFinished({
      round: 1,
      call_id: "run-1",
      name: "run_moon",
      status: "ok",
      result: "{\"exit_code\":0}",
    }),
  ])
  let evidence = build_audit_evidence(None, answer, true)
  assert_true(evidence.verification_ran)
  assert_true(evidence.verified)
  assert_eq(evidence.conflicts.length(), 0)
}

///|
test "audit evidence invalidates verification after a later edit" {
  let answer = audit_answer("## 审计报告", [
    @runtime.ToolStarted({
      round: 0,
      call_id: "edit-1",
      name: "multi_edit",
      arguments: "{}",
    }),
    @runtime.ToolFinished({
      round: 0,
      call_id: "edit-1",
      name: "multi_edit",
      status: "ok",
      result: "applied",
    }),
    @runtime.ToolStarted({
      round: 1,
      call_id: "run-1",
      name: "run_moon",
      arguments: "{\"args\":\"test\"}",
    }),
    @runtime.ToolFinished({
      round: 1,
      call_id: "run-1",
      name: "run_moon",
      status: "ok",
      result: "{\"exit_code\":0}",
    }),
    @runtime.ToolStarted({
      round: 2,
      call_id: "edit-2",
      name: "write_file",
      arguments: "{}",
    }),
    @runtime.ToolFinished({
      round: 2,
      call_id: "edit-2",
      name: "write_file",
      status: "ok",
      result: "applied",
    }),
  ])
  let evidence = build_audit_evidence(None, answer, true)
  assert_true(!evidence.verification_ran)
  assert_true(!evidence.verified)
  assert_true(evidence.conflicts[0].contains("No post-fix"))
}

///|
fn test_verification(
  check_passed : Bool,
  build_passed : Bool,
  test_passed : Bool,
) -> AuditVerificationSummary {
  {
    check_passed,
    build_passed,
    test_passed,
    check_output: "check",
    build_output: "build",
    test_output: "test",
  }
}

///|
test "publish gate requires a real diff and all three final validations" {
  let passed = test_verification(true, true, true)
  assert_true(passed.passed())
  assert_eq(audit_publish_block_reason(passed, true), None)
  assert_eq(
    audit_publish_block_reason(passed, false),
    Some("no changes to publish (git diff is empty)"),
  )
  assert_eq(
    audit_publish_block_reason(test_verification(false, true, true), true),
    Some("moon check --target native failed"),
  )
  assert_eq(
    audit_publish_block_reason(test_verification(true, false, true), true),
    Some("moon build --target native failed"),
  )
  assert_eq(
    audit_publish_block_reason(test_verification(true, true, false), true),
    Some("moon test --target native failed"),
  )
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
test "parse_audit_options supports standalone --clean" {
  let clean_only = parse_audit_options(["--clean"]) catch {
    _ => audit_default_options()
  }
  assert_eq(clean_only.name, "")
  assert_true(clean_only.clean)
  let combined = parse_audit_options(["owner/mod", "--clean"]) catch {
    _ => audit_default_options()
  }
  assert_eq(combined.name, "owner/mod")
  assert_true(combined.clean)
  let flags_first = parse_audit_options([
    "--clean", "owner/mod", "--max-calls", "10",
  ]) catch {
    _ => audit_default_options()
  }
  assert_eq(flags_first.name, "owner/mod")
  assert_true(flags_first.clean)
  assert_eq(flags_first.max_calls, 10)
}

///|
async test "clean_audit_temp_dirs removes leftover audit workspaces" {
  let dir1 = @fs.tmpdir(prefix="moonsage-audit-test-")
  let dir2 = @fs.tmpdir(prefix="moonsage-audit-test-")
  let kind1 = @fs.kind(dir1) catch { _ => @fs.FileKind::Unknown }
  assert_true(kind1 is @fs.FileKind::Directory)
  let removed = clean_audit_temp_dirs()
  assert_true(removed >= 2)
  let kind1_after = @fs.kind(dir1) catch { _ => @fs.FileKind::Unknown }
  let kind2_after = @fs.kind(dir2) catch { _ => @fs.FileKind::Unknown }
  assert_true(!(kind1_after is @fs.FileKind::Directory))
  assert_true(!(kind2_after is @fs.FileKind::Directory))
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

///|
test "pr title branch and email builders" {
  assert_eq(
    @editing.pr_title("owner", "repo"),
    "fix: apply MoonSage audit fixes to owner/repo",
  )
  assert_eq(@editing.pr_branch_name("repo"), "moonsage/fix-repo")
  assert_eq(
    @editing.pr_commit_email("Asterless", 79297402),
    "79297402+Asterless@users.noreply.github.com",
  )
  assert_true(
    @editing.build_pr_body("报告", "o", "r").contains("Generated by MoonSage"),
  )
}

///|
test "fix phase prompt prefers local edits and analysis stays read-only" {
  assert_true(audit_fix_prompt().contains("Prefer multi_edit"))
  assert_true(audit_fix_prompt().contains("write_file"))
  assert_true(audit_fix_prompt().contains("remove"))
  assert_true(audit_fix_prompt().contains("## 审计报告"))
  assert_true(!audit_analysis_prompt().contains("write_file"))
  assert_true(audit_analysis_prompt().length() > 0)
  assert_true(audit_analysis_question().contains("分析结果"))
  assert_true(audit_fix_question("某个根因").contains("某个根因"))
  assert_true(audit_fix_question("某个根因").contains("分析结果"))
}

///|
test "structured audit publish gate requires evidence diff and all validations" {
  let result : StructuredAuditResult = {
    status: Completed,
    project_dir: "C:/project",
    report: "fixed",
    analysis: "issue",
    diff: "diff --git a/a.mbt b/a.mbt",
    evidence: {
      tools: [],
      verification_ran: true,
      verified: true,
      conflicts: [],
    },
    validation: {
      check_passed: true,
      build_passed: true,
      test_passed: true,
      check_output: "ok",
      build_output: "ok",
      test_output: "ok",
    },
    error: "",
  }
  assert_true(result.publishable())
  let failed = {
    ..result,
    validation: { ..result.validation, test_passed: false },
  }
  assert_true(!failed.publishable())
}

///|
test "controller verification invalidates evidence when the final diff changes" {
  let evidence : AuditEvidence = {
    tools: [],
    verification_ran: true,
    verified: true,
    conflicts: [],
  }
  let unchanged = finalize_controller_evidence(
    evidence, "diff --git a/a.mbt b/a.mbt\n+before\n", "diff --git a/a.mbt b/a.mbt\n+before\n",
  )
  assert_true(unchanged.verified)
  assert_true(unchanged.conflicts.is_empty())
  let changed = finalize_controller_evidence(
    evidence, "diff --git a/a.mbt b/a.mbt\n+before\n", "diff --git a/a.mbt b/a.mbt\n+after\n",
  )
  assert_true(!changed.verified)
  assert_true(changed.conflicts.length() == 1)
  assert_true(changed.conflicts[0].contains("changed during"))
  let unreadable = finalize_controller_evidence(
    evidence, "diff --git a/a.mbt b/a.mbt\n+before\n", "(git diff failed)",
  )
  assert_true(!unreadable.verified)
  assert_true(unreadable.conflicts[0].contains("could not read"))
}

///|
async test "structured audit rejects missing credentials before external work" {
  let result = run_structured_audit_project(
    "", "https://example.invalid", "model", "C:/not-used",
  )
  assert_true(result.status is Failed)
  assert_true(result.error.contains("MOONSAGE_API_KEY"))
}

///|
async test "structured audit rejects a non MoonBit workspace before the model" {
  let workspace = @fs.tmpdir(prefix="moonsage-structured-audit-test-")
  let result = run_structured_audit_project(
    "test-key", "https://example.invalid", "model", workspace,
  )
  assert_true(result.status is Failed)
  assert_true(result.error.contains("moon.mod"))
  @fs.rmdir(workspace, recursive=true)
}
