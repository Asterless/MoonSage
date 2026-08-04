///|
// audit 命令的解析结果。
struct AuditOptions {
  mut name : String
  mut fix : Bool
  mut confirm : ConfirmMode
  mut workspace : String
  mut max_calls : Int
  max_rounds : Int
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
  }
}

///|

///|
fn parse_audit_options(args : ArrayView[String]) -> AuditOptions raise {
  let opts = audit_default_options()
  guard args.length() >= 1 else {
    fail(
      "usage: audit <owner/module> [--fix] [--confirm prompt|diff|yes] [--workspace <dir>] [--max-calls <n>]",
    )
  }
  opts.name = args[0]
  let mut i = 1
  while i < args.length() {
    match args[i] {
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
        opts.max_calls = parse_int_or(args[i + 1], 30)
        i += 1
      }
      _ => fail("unknown audit flag: \{args[i]}")
    }
    i += 1
  }
  opts
}

///|
fn parse_int_or(s : String, default : Int) -> Int {
  @string.parse_int(s) catch {
    _ => default
  }
}

///|
fn audit_system_prompt() -> String {
  (
    #|You are MoonSage's remote audit agent. A MoonBit project has been
    #|downloaded to a working directory. You can list files, read files, run
    #|moon commands (build/test), and - only in fix mode - overwrite files.
    #|
    #|Workflow:
    #|1. Run `moon build` and `moon test` first to establish a baseline and
    #|   record any failures.
    #|2. Inspect the relevant source and test files to find root causes.
    #|3. In fix mode, apply minimal fixes with write_file, then re-run the
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
  )
}

///|
// 独立的审计 agent 循环：使用审计工具集与更高预算，复用 LLM 流式调用。
async fn run_audit_agent(
  api_key : String,
  base_url : String,
  model : String,
  ctx : AuditContext,
  question : String,
  max_tool_calls~ : Int,
  max_rounds~ : Int,
) -> LlmAgentAnswer {
  let messages : Array[Json] = [
    chat_message("system", audit_system_prompt()),
    chat_message("user", question),
  ]
  let tools_json = audit_tool_schemas(ctx.fix).map(fn(t) { t.to_json() })
  let trace : Array[String] = ["[plan] Start remote audit"]
  let mut step = 0
  let mut total_tool_calls = 0
  let mut budget_exhausted = false
  while step < max_rounds && !budget_exhausted {
    if total_tool_calls >= max_tool_calls {
      budget_exhausted = true
      break
    }
    let result = stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      tools_json,
      max_tokens=2000,
      on_delta=ignore_delta,
    )
    if result.tool_calls.is_empty() {
      guard result.content != "" else { fail("model returned an empty answer") }
      trace.push("[final] Audit finished")
      return { text: result.content, trace }
    }
    messages.push(
      assistant_message_with_tool_calls(result.content, result.tool_calls),
    )
    for call in result.tool_calls {
      if total_tool_calls >= max_tool_calls {
        budget_exhausted = true
        messages.push(
          tool_result_message(
            call.id,
            error_json("tool call skipped: agent budget exhausted"),
          ),
        )
        continue
      }
      total_tool_calls += 1
      trace.push("[tool] \{call.name}")
      let call_result = run_audit_tool(ctx, call.name, call.arguments)
      messages.push(tool_result_message(call.id, call_result))
      trace.push("[observation] \{call.name} completed")
    }
    step += 1
  }
  if !budget_exhausted && step >= max_rounds {
    budget_exhausted = true
  }
  if budget_exhausted {
    trace.push(
      "[observation] Audit budget exhausted; requesting a final report from collected evidence",
    )
    messages.push(
      chat_message(
        "user", "(System: no more tool calls are allowed. Write the audit report now using the evidence already collected. 用简体中文输出完整报告。)",
      ),
    )
    // 不再暴露任何工具，模型只能输出纯文本报告。
    let result = stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      [],
      max_tokens=2000,
      on_delta=ignore_delta,
    )
    if result.content != "" {
      trace.push("[final] Audit report from collected evidence")
      return { text: result.content, trace }
    }
    messages.push(
      chat_message(
        "user", "(System: your previous reply was empty. Output the audit report as plain text now. 用简体中文输出。)",
      ),
    )
    let retry = stream_chat_completion(
      api_key,
      base_url,
      model,
      messages,
      [],
      max_tokens=2000,
      on_delta=ignore_delta,
    )
    if retry.content != "" {
      trace.push("[final] Audit report (retried)")
      return { text: retry.content, trace }
    }
    fail("model could not produce an audit report")
  }
  fail("audit loop terminated without an answer")
}

///|
fn audit_question_text() -> String {
  (
    #|Audit this MoonBit project for bugs: build failures, test failures,
    #|logic errors, and unsafe or incorrect code. In fix mode, apply and
    #|verify fixes. Write the final report in Simplified Chinese (简体中文),
    #|using Markdown headings, lists and code blocks.
  )
}

///|
async fn run_audit(args : ArrayView[String]) -> Unit {
  let opts = parse_audit_options(args) catch {
    e => {
      println("error: \{e.to_string()}")
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

  @stdio.stdout.write("MoonSage audit\n")
  @stdio.stdout.write("Fetching manifest for \{opts.name}...\n")
  guard valid_module_name(opts.name) else {
    println("error: invalid module name: \{opts.name}")
    return
  }
  let manifest = fetch_asset(
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
  let project_dir = fetch_repo_source(owner, repo, workspace) catch {
    e => {
      println("error: \{e.to_string()}")
      return
    }
  }
  @stdio.stdout.write("Project ready at \{project_dir}\n")
  if opts.fix {
    let mode = match opts.confirm {
      ConfirmPrompt => "prompt"
      ConfirmDiff => "diff"
      ConfirmYes => "yes"
    }
    @stdio.stdout.write("Fix mode enabled (confirm: \{mode})\n")
  }
  let ctx : AuditContext = { project_dir, fix: opts.fix, confirm: opts.confirm }
  let answer = run_audit_agent(
    key,
    base_url,
    model,
    ctx,
    audit_question_text(),
    max_tool_calls=opts.max_calls,
    max_rounds=opts.max_rounds,
  ) catch {
    e => {
      println("error: audit failed: \{e.to_string()}")
      return
    }
  }
  @stdio.stdout.write("\n")
  let rendered = render_md_to_ansi(answer.text) catch { _ => answer.text }
  @stdio.stdout.write(rendered + ansi_reset + "\n")
  if opts.fix {
    @stdio.stdout.write("\n=== changes ===\n")
    @stdio.stdout.write(git_diff(project_dir, None))
  }
  @stdio.stdout.write("\n")
  for event in answer.trace {
    @stdio.stdout.write(event + "\n")
  }
}
