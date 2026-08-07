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
    #|Your ONLY job is to APPLY those fixes with write_file, one issue at a
    #|time, and verify each with `moon build` / `moon test`.
    #|
    #|Workflow:
    #|1. Take the first issue from the analysis.
    #|2. Call write_file immediately to apply its fix - do not re-read the
    #|   whole project or re-diagnose.
    #|3. Re-run the relevant moon command to confirm the fix.
    #|4. Move to the next issue and repeat.
    #|5. Finish with a report in Simplified Chinese starting with
    #|   "## 审计报告": what was fixed, before/after test results, and any
    #|   problems that remain.
    #|
    #|Rules:
    #|- write_file is available and is the ONLY way to modify files. You MUST
    #|  call it for every fix; analyzing or recommending without writing
    #|  counts as failure.
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
    #|with write_file, verifying each with moon build/test, then write the
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
// 第一阶段：只读分析，小预算，输出根因与具体修复方案。
async fn run_analysis_agent(
  api_key : String,
  base_url : String,
  model : String,
  ctx : AuditContext,
) -> @agent.AgentAnswer {
  let ro_ctx : AuditContext = {
    project_dir: ctx.project_dir,
    fix: false,
    confirm: ctx.confirm,
  }
  let agent : @agent.Agent = {
    system_prompt: audit_analysis_prompt(),
    tools: audit_tools(ro_ctx),
    max_tool_calls: 12,
    max_rounds: 4,
    max_tokens: 4000,
  }
  agent.run(api_key, base_url, model, audit_analysis_question())
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
) -> @agent.AgentAnswer {
  let agent : @agent.Agent = {
    system_prompt: audit_fix_prompt(),
    tools: audit_tools(ctx),
    max_tool_calls,
    max_rounds,
    max_tokens: 6000,
  }
  agent.run(api_key, base_url, model, audit_fix_question(findings))
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
    let analysis = run_analysis_agent(key, base_url, model, ctx) catch {
      e => {
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: analysis phase failed: \{e.to_string()}")
        return
      }
    }
    @stdio.stdout.write("Phase 2/2: applying fixes...\n")
    let answer = run_fix_agent(
      key,
      base_url,
      model,
      ctx,
      analysis.text,
      max_tool_calls=opts.max_calls,
      max_rounds=opts.max_rounds,
    ) catch {
      e => {
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: fix phase failed: \{e.to_string()}")
        return
      }
    }
    print_agent_report(answer.text)
    @stdio.stdout.write("\n=== changes ===\n")
    @stdio.stdout.write(@local.git_diff(project_dir, None))
    if opts.pr {
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
    @stdio.stdout.write("\n--- analysis trace ---\n")
    for event in analysis.trace {
      @stdio.stdout.write(event + "\n")
    }
    @stdio.stdout.write("\n--- fix trace ---\n")
    for event in answer.trace {
      @stdio.stdout.write(event + "\n")
    }
  } else {
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
        if opts.clean {
          remove_workspace_dir(workspace)
        }
        println("error: audit failed: \{e.to_string()}")
        return
      }
    }
    print_agent_report(answer.text)
    @stdio.stdout.write("\n")
    for event in answer.trace {
      @stdio.stdout.write(event + "\n")
    }
  }
  if opts.clean {
    remove_workspace_dir(workspace)
  }
}
