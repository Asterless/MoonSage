///|
// audit 命令的解析结果。
priv struct AuditOptions {
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
    #|- Your final reply must BE the report itself, starting directly with
    #|  "## 审计报告". Never include reasoning, planning, "Let me...", or any
    #|  analysis narrative in the final reply - the report is all that is
    #|  shown to the user.
    #|- In fix mode, analyzing without writing counts as failure: you MUST
    #|  actually call write_file to apply each fix, then re-run the relevant
    #|  moon command to verify it, before writing the report.
    #|- In fix mode, fix issues one at a time as you find them: apply the fix
    #|  and verify it immediately, instead of reading every file first.
    #|- A fix ONLY counts when you actually call the write_file tool. Never
    #|  write code patches, tool invocations or XML into the report text.
  )
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
) -> @agent.AgentAnswer {
  let agent : @agent.Agent = {
    system_prompt: audit_system_prompt(),
    tools: audit_tools(ctx),
    max_tool_calls,
    max_rounds,
    max_tokens: 6000,
  }
  agent.run(api_key, base_url, model, question)
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
  let rendered = @md_ansi.render_md_to_ansi(answer.text) catch {
    _ => answer.text
  }
  @stdio.stdout.write(rendered + "\u001B[0m" + "\n")
  if opts.fix {
    @stdio.stdout.write("\n=== changes ===\n")
    @stdio.stdout.write(git_diff(project_dir, None))
  }
  @stdio.stdout.write("\n")
  for event in answer.trace {
    @stdio.stdout.write(event + "\n")
  }
}
