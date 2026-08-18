///|
// audit 命令的解析结果。
priv struct AuditOptions {
  mut name : String
  mut fix : Bool
  mut confirm : ConfirmMode
  mut workspace : String
  mut max_calls : Int
  max_rounds : Int
  mut clean : Bool
  mut pr : Bool
}

///|
pub(all) struct AuditToolRecord {
  phase : String
  round : Int
  call_id : String
  name : String
  arguments : String
  status : String
  result : String
}

///|
pub(all) struct AuditEvidence {
  tools : Array[AuditToolRecord]
  verification_ran : Bool
  verified : Bool
  conflicts : Array[String]
}

///|
/// Final controller-owned verification. These commands run after the agent
/// has finished editing, so a later edit cannot invalidate the evidence used
/// by the publisher.
pub(all) struct AuditVerificationSummary {
  check_passed : Bool
  build_passed : Bool
  test_passed : Bool
  check_output : String
  build_output : String
  test_output : String
} derive(Eq, Debug)

///|
pub fn AuditVerificationSummary::passed(
  self : AuditVerificationSummary,
) -> Bool {
  self.check_passed && self.build_passed && self.test_passed
}

///|
fn verification_output_passed(output : String) -> Bool {
  tool_exit_code(output) is Some(0)
}

///|
pub async fn run_final_audit_verification(
  project_dir : String,
  timeout_ms? : Int = 300000,
) -> AuditVerificationSummary {
  let check_output = @local.run_moon_verification(
    project_dir,
    "check",
    timeout_ms~,
  )
  let build_output = @local.run_moon_verification(
    project_dir,
    "build",
    timeout_ms~,
  )
  let test_output = @local.run_moon_verification(
    project_dir,
    "test",
    timeout_ms~,
  )
  {
    check_passed: verification_output_passed(check_output),
    build_passed: verification_output_passed(build_output),
    test_passed: verification_output_passed(test_output),
    check_output,
    build_output,
    test_output,
  }
}

///|
async fn audit_worktree_has_changes(project_dir : String) -> Bool {
  let (exit, out, _) = @process.collect_output(
    "git",
    ["status", "--porcelain", "--untracked-files=all"],
    cwd=project_dir,
    no_console_window=true,
  )
  exit == 0 && (out.text() catch { _ => "" }).trim() != ""
}

///|
pub fn audit_publish_block_reason(
  verification : AuditVerificationSummary,
  has_changes : Bool,
) -> String? {
  if !has_changes {
    Some("no changes to publish (git diff is empty)")
  } else if !verification.check_passed {
    Some("moon check --target native failed")
  } else if !verification.build_passed {
    Some("moon build --target native failed")
  } else if !verification.test_passed {
    Some("moon test --target native failed")
  } else {
    None
  }
}

///|
async fn print_final_verification(
  verification : AuditVerificationSummary,
) -> Unit {
  @stdio.stdout.write("\n--- final verification ---\n")
  for
    entry in [
      ("check", verification.check_passed, verification.check_output),
      ("build", verification.build_passed, verification.build_output),
      ("test", verification.test_passed, verification.test_output),
    ] {
    let (command, passed, output) = entry
    @stdio.stdout.write(
      "moon \{command} --target native: \{if passed { "passed" } else { "failed" }}\n",
    )
    if !passed {
      @stdio.stdout.write(output + "\n")
    }
  }
}

///|
fn tool_exit_code(result : String) -> Int? {
  let document = @json.parse(result) catch { _ => return None }
  guard document is Object(fields) else { return None }
  match fields.get("exit_code") {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn collect_tool_records(
  answer : @runtime.AgentAnswer,
  phase : String,
) -> Array[AuditToolRecord] {
  let started : Map[String, @runtime.ToolStartedEvent] = Map([])
  let records : Array[AuditToolRecord] = []
  for event in answer.events {
    match event {
      ToolStarted(item) => started[item.call_id] = item
      ToolFinished(item) => {
        let begin = started.get(item.call_id)
        records.push({
          phase,
          round: item.round,
          call_id: item.call_id,
          name: item.name,
          arguments: match begin {
            Some(value) => value.arguments
            None => ""
          },
          status: item.status,
          result: item.result,
        })
      }
      _ => ()
    }
  }
  records
}

///|
fn report_claims_verification(text : String) -> Bool {
  let lower = text.to_lower()
  text.contains("测试通过") ||
  text.contains("验证通过") ||
  lower.contains("tests pass") ||
  lower.contains("verified")
}

///|
pub fn build_audit_evidence(
  baseline : @runtime.AgentAnswer?,
  answer : @runtime.AgentAnswer,
  fix_mode : Bool,
) -> AuditEvidence {
  let mut tools : Array[AuditToolRecord] = []
  match baseline {
    Some(value) => tools = tools + collect_tool_records(value, "baseline")
    None => ()
  }
  tools = tools +
    collect_tool_records(answer, if fix_mode { "fix" } else { "audit" })
  let mut modified = false
  let mut verification_ran = false
  let mut verification_succeeded = false
  let mut last_verification_exit : Int? = None
  for tool in tools {
    if (
        tool.name == "write_file" ||
        tool.name == "multi_edit" ||
        tool.name == "remove"
      ) &&
      tool.status == "ok" {
      modified = true
      verification_ran = false
      verification_succeeded = false
      last_verification_exit = None
    }
    if tool.name == "run_moon" && (!fix_mode || modified) {
      verification_ran = true
      last_verification_exit = tool_exit_code(tool.result)
      verification_succeeded = last_verification_exit is Some(0)
    }
  }
  let verified = if fix_mode {
    modified && verification_ran && verification_succeeded
  } else {
    verification_ran && verification_succeeded
  }
  let conflicts : Array[String] = []
  if fix_mode && modified && !verification_ran {
    conflicts.push("No post-fix moon verification command was run.")
  } else if fix_mode && modified && verification_ran && !verification_succeeded {
    conflicts.push("The post-fix moon verification command failed.")
  }
  if report_claims_verification(answer.text) &&
    last_verification_exit is Some(code) &&
    code != 0 {
    conflicts.push(
      "The model report claims verification succeeded, but the recorded exit code was \{code}.",
    )
  }
  { tools, verification_ran, verified, conflicts }
}

///|
async fn print_audit_evidence(evidence : AuditEvidence) -> Unit {
  @stdio.stdout.write("\n--- structured evidence ---\n")
  for tool in evidence.tools {
    @stdio.stdout.write(
      "[\{tool.phase}] round=\{tool.round} \{tool.name} call_id=\{tool.call_id} status=\{tool.status} args=\{tool.arguments}\n",
    )
    if tool.name == "run_moon" {
      @stdio.stdout.write(tool.result + "\n")
    }
  }
  @stdio.stdout.write(
    "verification_ran=\{evidence.verification_ran} verified=\{evidence.verified}\n",
  )
  for conflict in evidence.conflicts {
    @stdio.stdout.write("CONFLICT: \{conflict}\n")
  }
}

///|
fn audit_default_options() -> AuditOptions {
  {
    name: "",
    fix: false,
    confirm: ConfirmDiff,
    workspace: "",
    max_calls: 30,
    max_rounds: 8,
    clean: false,
    pr: false,
  }
}

///|
fn parse_audit_options(args : ArrayView[String]) -> AuditOptions raise {
  let opts = audit_default_options()
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--clean" => opts.clean = true
      "--pr" => opts.pr = true
      "--fix" => opts.fix = true
      "--confirm" => {
        guard i + 1 < args.length() else { fail("--confirm requires a mode") }
        opts.confirm = match args[i + 1] {
          "prompt" => ConfirmPrompt
          "diff" => ConfirmDiff
          "yes" => ConfirmYes
          _ => fail("--confirm must be prompt|diff|yes")
        }
        i += 1
      }
      "--workspace" => {
        guard i + 1 < args.length() else {
          fail("--workspace requires a directory")
        }
        opts.workspace = args[i + 1]
        i += 1
      }
      "--max-calls" => {
        guard i + 1 < args.length() else {
          fail("--max-calls requires a number")
        }
        opts.max_calls = @util.parse_int_or(args[i + 1], 30)
        i += 1
      }
      _ => {
        guard opts.name == "" else { fail("unexpected argument: \{args[i]}") }
        opts.name = args[i]
      }
    }
    i += 1
  }
  if opts.pr {
    opts.fix = true
  }
  guard opts.name != "" || opts.clean else {
    fail(
      "usage: audit <owner/module> [--fix] [--confirm prompt|diff|yes] [--workspace <dir>] [--max-calls <n>] [--clean]",
    )
  }
  opts
}

///|
fn audit_system_prompt() -> String {
  (
    #|You are MoonSage's remote audit agent. A MoonBit project has been
    #|downloaded to a working directory. You can list files, read files, run
    #|moon commands (build/test), and - only in fix mode - edit files.
    #|
    #|Workflow:
    #|1. Run `moon build` and `moon test` first to establish a baseline and
    #|   record any failures.
    #|2. Inspect the relevant source and test files to find root causes.
    #|3. In fix mode, apply minimal fixes with multi_edit, then re-run the
    #|   relevant moon command to confirm each fix.
    #|4. Finish with a report written in Simplified Chinese (简体中文) listing
    #|   (file and line), what was fixed, test results before/after, and any
    #|   problems that remain.
    #|
    #|Rules:
    #|- Never claim a fix works without running moon build/test afterwards.
    #|- Keep changes minimal and focused on real bugs.
    #|- If the project already builds and tests pass, say so instead of
    #|  inventing problems.
    #|- Be honest about anything you could not fix within the budget.
    #|- Your final reply must BE the report itself, starting directly with
    #|  "## 审计报告". Never include reasoning, planning, "Let me...", or any
    #|  analysis narrative in the final reply - the report is all that is
    #|  shown to the user.
    #|- In fix mode, analyzing without writing counts as failure: you MUST
    #|  actually call multi_edit/write_file/remove to apply each fix, then
    #|  re-run the relevant
    #|  moon command to verify it, before writing the report.
    #|- In fix mode, fix issues one at a time as you find them: apply the fix
    #|  and verify it immediately, instead of reading every file first.
    #|- Prefer multi_edit for existing files. Use write_file only to add a
    #|  small new file, and remove only when deletion is required. A fix ONLY
    #|  counts when one of these tools succeeds. Never
    #|  write code patches, tool invocations or XML into the report text.
  )
}

///|
fn audit_analysis_prompt() -> String {
  (
    #|You are MoonSage's audit analysis agent. A MoonBit project has been
    #|downloaded to a working directory. Your ONLY job is to find root causes
    #|and list concrete minimal fixes. You must NOT modify any file.
    #|
    #|Workflow:
    #|1. Run `moon build` and `moon test` first to record the baseline.
    #|2. Inspect only the relevant source and test files to find root causes.
    #|   Stop reading once the causes are clear - do not read the whole
    #|   project.
    #|3. For each issue, give the file path, the root cause, and a concrete
    #|   minimal fix (either the exact replacement content or the exact edit).
    #|
    #|Rules:
    #|- Never claim a fix works without running moon build/test.
    #|- If the project already builds and tests pass, say so instead of
    #|  inventing problems.
    #|- Be honest about anything you could not determine within the budget.
    #|- Your final reply must BE the analysis, in Simplified Chinese,
    #|  starting with "## 分析结果". Do not include reasoning, planning or
    #|  "Let me..." narrative - the analysis is all that is shown.
  )
}

///|
fn audit_fix_prompt() -> String {
  (
    #|You are MoonSage's fix agent. A MoonBit project has been downloaded and
    #|analyzed; the analysis with concrete fixes is in the user's question.
    #|Your ONLY job is to APPLY those fixes with the editing tools, one issue at a
    #|time, and verify each with `moon build` / `moon test`.
    #|
    #|Workflow:
    #|1. Take the first issue from the analysis.
    #|2. Call multi_edit immediately for an existing file - do not re-read the
    #|   whole project or re-diagnose.
    #|3. Re-run the relevant moon command to confirm the fix.
    #|4. Move to the next issue and repeat.
    #|5. Finish with a report in Simplified Chinese starting with
    #|   "## 审计报告": what was fixed, before/after test results, and any
    #|   problems that remain.
    #|
    #|Rules:
    #|- Prefer multi_edit for precise changes to existing files. Use
    #|  write_file only for a small new file, and remove only for deletion.
    #|  Analyzing or recommending without a successful edit counts as failure.
    #|- Fix one issue at a time and verify it immediately.
    #|- Never claim a fix works without running moon build/test afterwards.
    #|- Never write code patches, tool invocations or XML into the report
    #|  text.
    #|- Be honest about anything you could not fix within the budget.
  )
}

///|
fn audit_analysis_question() -> String {
  (
    #|Find the root causes of build failures, test failures, logic errors,
    #|and unsafe or incorrect code. Do not modify any file. Write a concise
    #|analysis in Simplified Chinese starting with "## 分析结果".
  )
}

///|
fn audit_fix_question(findings : String) -> String {
  (
    #|The analysis below lists the issues and concrete fixes. Apply them now
    #|with multi_edit/write_file/remove, verifying each with moon build/test,
    #|then write the
    #|final report in Simplified Chinese starting with "## 审计报告".
    #|
    #|## 分析结果
    #|
  ) +
  findings
}

///|
// 独立的审计 agent 循环：使用审计工具集与更高预算，复用 LLM 流式调用。

///|
// 复用通用 Agent 循环：装配审计工具集，并使用更高的调用/轮次预算。
async fn run_audit_agent(
  api_key : String,
  base_url : String,
  model : String,
  ctx : AuditContext,
  question : String,
  max_tool_calls~ : Int,
  max_rounds~ : Int,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  provider? : @llm.ProviderKind = OpenAi,
) -> @runtime.AgentAnswer {
  let agent : @runtime.Agent = {
    system_prompt: audit_system_prompt(),
    tools: audit_tools(ctx),
    max_tool_calls,
    max_rounds,
    max_tokens: 6000,
  }
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  agent.execute(
    client,
    question,
    on_event~,
    context_window_tokens=32768,
    reserved_output_tokens=6000,
  )
}

///|
// 第一阶段：只读分析，小预算，输出根因与具体修复方案。
async fn run_analysis_agent(
  api_key : String,
  base_url : String,
  model : String,
  ctx : AuditContext,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  restricted_moon? : Bool = false,
  provider? : @llm.ProviderKind = OpenAi,
) -> @runtime.AgentAnswer {
  let ro_ctx : AuditContext = {
    project_dir: ctx.project_dir,
    fix: false,
    confirm: ctx.confirm,
  }
  let agent : @runtime.Agent = {
    system_prompt: audit_analysis_prompt(),
    tools: audit_tools(ro_ctx, restricted_moon~),
    max_tool_calls: 12,
    max_rounds: 4,
    max_tokens: 4000,
  }
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  agent.execute(
    client,
    audit_analysis_question(),
    on_event~,
    context_window_tokens=32768,
    reserved_output_tokens=4000,
  )
}

///|
// 第二阶段（仅 --fix）：携带分析结果，强制先写文件再验证。
async fn run_fix_agent(
  api_key : String,
  base_url : String,
  model : String,
  ctx : AuditContext,
  findings : String,
  max_tool_calls~ : Int,
  max_rounds~ : Int,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  restricted_moon? : Bool = false,
  provider? : @llm.ProviderKind = OpenAi,
) -> @runtime.AgentAnswer {
  let agent : @runtime.Agent = {
    system_prompt: audit_fix_prompt(),
    tools: audit_tools(ctx, restricted_moon~),
    max_tool_calls,
    max_rounds,
    max_tokens: 6000,
  }
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  agent.execute(
    client,
    audit_fix_question(findings),
    on_event~,
    context_window_tokens=32768,
    reserved_output_tokens=6000,
  )
}

///|
async fn print_agent_report(text : String) -> Unit {
  @stdio.stdout.write("\n")
  let rendered = @md_ansi.render_md_to_ansi(text) catch { _ => text }
  @stdio.stdout.write(rendered + "\u001B[0m" + "\n")
}

///|
fn audit_question_text() -> String {
  (
    #|Audit this MoonBit project for bugs: build failures, test failures,
    #|logic errors, and unsafe or incorrect code. In fix mode, apply and
    #|verify fixes. Write the final report in Simplified Chinese (简体中文),
    #|using Markdown headings, lists and code blocks. The final reply must be
    #|the report itself starting with "## 审计报告" - do not output any
    #|reasoning or analysis narrative in it.
  )
}

///|
pub async fn run_audit(args : ArrayView[String]) -> Unit {
  let opts = parse_audit_options(args) catch {
    e => {
      println("error: \{e.to_string()}")
      return
    }
  }
  if opts.clean && opts.name == "" {
    let root = audit_temp_root()
    let removed = clean_audit_temp_dirs()
    if removed == 0 {
      println("no leftover audit workspaces in \{root}")
    } else {
      println("removed \{removed} audit workspace(s) from \{root}")
    }
    return
  }
  guard !(opts.clean && opts.workspace != "") else {
    println("error: --clean cannot be combined with --workspace")
    return
  }
  if opts.pr {
    let (gh_exit, _, _) = @process.collect_output(
      "gh",
      ["api", "user"],
      no_console_window=true,
    )
    guard gh_exit == 0 else {
      println("error: --pr requires GitHub CLI (gh) authenticated")
      return
    }
  }
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    println("error: set MOONSAGE_API_KEY before using audit")
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let provider = @llm.provider_from_string(
    @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
  )

  @stdio.stdout.write("MoonSage audit\n")
  @stdio.stdout.write("Fetching manifest for \{opts.name}...\n")
  guard @mooncakes.valid_module_name(opts.name) else {
    println("error: invalid module name: \{opts.name}")
    return
  }
  let manifest = @mooncakes.fetch_asset(
    "https://mooncakes.io/api/v0/manifest/\{opts.name}",
    "Mooncakes manifest API",
  ) catch {
    e => {
      println("error: \{e.to_string()}")
      return
    }
  }
  let repo_url = manifest_repository(manifest) catch {
    e => {
      println("error: \{e.to_string()}")
      return
    }
  }
  let (owner, repo) = match parse_github_repo(repo_url) {
    Some(pair) => pair
    None => {
      println("error: unsupported repository: \{repo_url}")
      return
    }
  }
  let workspace = if opts.workspace != "" {
    opts.workspace
  } else {
    @fs.tmpdir(prefix="moonsage-audit-")
  }
  if opts.workspace != "" {
    @fs.mkdir(workspace, recursive=true) catch {
      e => {
        println("error: cannot create workspace \{workspace}: \{e.to_string()}")
        return
      }
    }
  }
  @stdio.stdout.write("Downloading \{owner}/\{repo}...\n")
  let project_dir = fetch_repo_source(owner, repo, workspace, full=opts.pr) catch {
    e => {
      if opts.clean {
        remove_workspace_dir(workspace)
      }
      println("error: \{e.to_string()}")
      return
    }
  }
  @stdio.stdout.write("Project ready at \{project_dir}\n")
  let ctx : AuditContext = { project_dir, fix: opts.fix, confirm: opts.confirm }
  if opts.fix {
    let mode = match opts.confirm {
      ConfirmPrompt => "prompt"
      ConfirmDiff => "diff"
      ConfirmYes => "yes"
    }
    @stdio.stdout.write("Fix mode enabled (confirm: \{mode})\n")
    if opts.pr {
      @stdio.stdout.write(
        "PR mode enabled: changes will be pushed as a pull request\n",
      )
    }
    @stdio.stdout.write("Phase 1/2: analyzing the project...\n")
    let analysis_events : Array[@runtime.EngineEvent] = []
    let analysis = run_analysis_agent(
      key,
      base_url,
      model,
      ctx,
      on_event=fn(event) { analysis_events.push(event) },
      provider~,
    ) catch {
      e => {
        print_audit_evidence(
          build_audit_evidence(
            None,
            @runtime.AgentAnswer::new("", [], analysis_events),
            false,
          ),
        )
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: analysis phase failed: \{e.to_string()}")
        return
      }
    }
    @stdio.stdout.write("Phase 2/2: applying fixes...\n")
    let fix_events : Array[@runtime.EngineEvent] = []
    let answer = run_fix_agent(
      key,
      base_url,
      model,
      ctx,
      analysis.text,
      max_tool_calls=opts.max_calls,
      max_rounds=opts.max_rounds,
      on_event=fn(event) { fix_events.push(event) },
      provider~,
    ) catch {
      e => {
        print_audit_evidence(
          build_audit_evidence(
            Some(analysis),
            @runtime.AgentAnswer::new("", [], fix_events),
            true,
          ),
        )
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: fix phase failed: \{e.to_string()}")
        return
      }
    }
    print_agent_report(answer.text)
    let evidence = build_audit_evidence(Some(analysis), answer, true)
    print_audit_evidence(evidence)
    @stdio.stdout.write("\n=== changes ===\n")
    let diff = @local.git_diff(project_dir, None)
    @stdio.stdout.write(diff)
    if opts.pr {
      let final_verification = run_final_audit_verification(project_dir)
      print_final_verification(final_verification)
      let block = audit_publish_block_reason(
        final_verification,
        audit_worktree_has_changes(project_dir),
      )
      match block {
        Some(reason) =>
          println(
            "error: publish blocked: \{reason}; the workspace was kept for inspection",
          )
        None => {
          let pr_url = @editing.publish_changes(
            project_dir,
            owner,
            repo,
            if opts.confirm is ConfirmPrompt {
              @editing.Prompt
            } else {
              @editing.Auto
            },
            answer.text,
          ) catch {
            e => {
              println("error: publish failed: \{e.to_string()}")
              None
            }
          }
          match pr_url {
            Some(url) => println("\nPR created: \{url}")
            None => ()
          }
        }
      }
    }
    @stdio.stdout.write("\n--- analysis trace ---\n")
    for event in analysis.trace {
      @stdio.stdout.write(event + "\n")
    }
    @stdio.stdout.write("\n--- fix trace ---\n")
    for event in answer.trace {
      @stdio.stdout.write(event + "\n")
    }
  } else {
    let audit_events : Array[@runtime.EngineEvent] = []
    let answer = run_audit_agent(
      key,
      base_url,
      model,
      ctx,
      audit_question_text(),
      max_tool_calls=opts.max_calls,
      max_rounds=opts.max_rounds,
      on_event=fn(event) { audit_events.push(event) },
      provider~,
    ) catch {
      e => {
        print_audit_evidence(
          build_audit_evidence(
            None,
            @runtime.AgentAnswer::new("", [], audit_events),
            false,
          ),
        )
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: audit failed: \{e.to_string()}")
        return
      }
    }
    print_agent_report(answer.text)
    print_audit_evidence(build_audit_evidence(None, answer, false))
    @stdio.stdout.write("\n")
    for event in answer.trace {
      @stdio.stdout.write(event + "\n")
    }
  }
  if opts.clean {
    remove_workspace_dir(workspace)
  }
}
