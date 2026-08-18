///|
fn usage() -> String {
  (
    #|MoonSage - an agent for the MoonBit package ecosystem
    #|
    #|Usage:
    #|  moonsage chat
    #|  moonsage tui
    #|  moonsage search <keywords>
    #|  moonsage ask [--stream-json] <question>
    #|  moonsage task [--workspace <dir>] [--permission read-only|controlled-write|full-auto] [--stream-json] <goal>
    #|  moonsage audit <owner/module> [--fix] [--confirm prompt|diff|yes] [--workspace <dir>] [--max-calls <n>]
    #|  moonsage audit --clean
    #|  moonsage batch-audit [start] [options]
    #|  moonsage mode 1 [start] [options]
    #|  moonsage batch-audit status|pause|resume|cancel <batch-id>
    #|  moonsage batch-audit retry|publish <batch-id> --item <item-key>
    #|  moonsage --version
    #|
    #|Run `moonsage --help` for the full option reference.
    #|
    #|Environment:
    #|  MOONSAGE_API_KEY    required for chat/tui/ask/audit
    #|  MOONSAGE_BASE_URL   default: https://api.deepseek.com
    #|  MOONSAGE_MODEL      default: deepseek-chat
    #|  MOONSAGE_PROVIDER   openai (default), anthropic, or ollama
    #|  MOONSAGE_MCP        optional stdio MCP server JSON for ask
  )
}

///|
fn join_query(args : Array[String], start : Int) -> String {
  let out = StringBuilder::new()
  let mut index = start
  while index < args.length() {
    if index > start {
      out.write_char(' ')
    }
    out.write_string(args[index])
    index += 1
  }
  out.to_string()
}

///|
async fn run_search(query : String) -> Unit {
  let modules = @mooncakes.fetch_modules()
  let answer = @search.run_search_agent(modules, query)
  println(@search.render_search_answer(answer))
}

///|
async fn write_json_event(event : @runtime.EngineEvent) -> Unit {
  @stdio.stdout.write(@protocol.event_to_json(event).stringify() + "\n")
}

///|
async fn configured_mcp_tools() -> Array[@tools.Tool] {
  let raw = @sys.get_env_var("MOONSAGE_MCP").unwrap_or("").trim()
  if raw == "" {
    return []
  }
  let document = @json.parse(raw)
  guard @tools.McpServerConfig::from_json(document) is Some(config) else {
    fail("MOONSAGE_MCP must be a JSON object with name and command")
  }
  @tools.mcp_tools(config)
}

///|
async fn run_ask(question : String, stream_json? : Bool = false) -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    if stream_json {
      write_json_event(Error("set MOONSAGE_API_KEY before using ask"))
    } else {
      @stdio.stderr.write("error: set MOONSAGE_API_KEY before using ask\n") catch {
        _ => ()
      }
    }
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let provider = @ai.provider_from_string(
    @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
  )
  let client = @ai.client(key, base_url, model, provider)
  let modules = @mooncakes.fetch_modules() catch {
    error => {
      if stream_json {
        write_json_event(Error(error.to_string()))
        return
      }
      @stdio.stderr.write("warning: \{error.to_string()}\n") catch {
        _ => ()
      }
      []
    }
  }
  let cwd = @env.current_dir().unwrap_or(".")
  let project_instructions = @project.load_project_instructions(cwd)
  let mcp_tools = configured_mcp_tools() catch {
    error => {
      if stream_json {
        write_json_event(Error(error.to_string()))
        return
      } else {
        @stdio.stderr.write("warning: \{error.to_string()}\n") catch {
          _ => ()
        }
      }
      []
    }
  }
  if stream_json {
    ignore(
      @research.run_research_agent(
        client,
        modules,
        question,
        on_event=async fn(event) { write_json_event(event) },
        extra_tools=mcp_tools,
        project_instructions~,
      ),
    ) catch {
      error => write_json_event(Error(error.to_string()))
    }
    return
  }
  @stdio.stdout.write("MoonSage\n")
  let printer = @md_ansi.MdStreamPrinter::new()
  let answer = @research.run_research_agent(
    client,
    modules,
    question,
    on_event=async fn(event) {
      match event {
        FinalDelta(text) => {
          printer.feed(text)
          let out = printer.take_output()
          if out != "" {
            @stdio.stdout.write(out)
          }
        }
        _ => ()
      }
    },
    extra_tools=mcp_tools,
    project_instructions~,
  )
  printer.finish()
  @stdio.stdout.write(printer.take_output())
  @stdio.stdout.write("\n")
  for event in answer.trace {
    println(event)
  }
  let _ = answer.text
}

///|
fn task_workspace(m : @argparse.Matches) -> String {
  match values_of(m, "workspace") {
    [path, ..] => path
    _ =>
      match values_of(m, "cwd") {
        [path, ..] => path
        _ => @env.current_dir().unwrap_or(".")
      }
  }
}

///|
fn task_permission(m : @argparse.Matches) -> @runtime.WorkspacePermission {
  match values_of(m, "permission") {
    [value, ..] => @runtime.workspace_permission_from_string(value)
    _ => @runtime.WorkspacePermission::ControlledWrite
  }
}

///|
/// Workspace-first task runner. Unlike `ask`, this does not load Mooncakes
/// research context or replay a conversation; the selected cwd is the agent's
/// only project context and local tools operate against that directory.
async fn run_task(m : @argparse.Matches) -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  let stream_json = flag_of(m, "stream-json")
  guard key != "" else {
    if stream_json {
      write_json_event(Error("set MOONSAGE_API_KEY before using task"))
    } else {
      @stdio.stderr.write("error: set MOONSAGE_API_KEY before using task\n") catch {
        _ => ()
      }
    }
    return
  }
  let goal = match values_of(m, "input-file") {
    [path, ..] => {
      let bytes = @fs.read_file(path).binary()
      @utf8.decode(bytes)
    }
    _ => join_values(m, "goal")
  }
  guard goal.trim() != "" else {
    if stream_json {
      write_json_event(Error("task goal is required"))
    } else {
      @stdio.stderr.write("error: task goal is required\n") catch {
        _ => ()
      }
    }
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let provider = @ai.provider_from_string(
    @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
  )
  let cwd = task_workspace(m)
  let project_instructions = @project.load_project_instructions(cwd)
  let agent = @runtime.workspace_agent(
    cwd,
    task_permission(m),
    project_instructions,
  )
  let client = @ai.client(key, base_url, model, provider)
  if stream_json {
    ignore(
      agent.execute(
        client,
        goal,
        on_event=async fn(event) { write_json_event(event) },
        context_window_tokens=32768,
        reserved_output_tokens=1600,
      ),
    ) catch {
      error => write_json_event(Error(error.to_string()))
    }
    return
  }
  @stdio.stdout.write("MoonSage task\n")
  let printer = @md_ansi.MdStreamPrinter::new()
  let answer = agent.execute(
    client,
    goal,
    on_event=async fn(event) {
      match event {
        FinalDelta(text) => {
          printer.feed(text)
          let out = printer.take_output()
          if out != "" {
            @stdio.stdout.write(out)
          }
        }
        _ => ()
      }
    },
    context_window_tokens=32768,
    reserved_output_tokens=1600,
  )
  printer.finish()
  @stdio.stdout.write(printer.take_output())
  @stdio.stdout.write("\n")
  for event in answer.trace {
    println(event)
  }
  let _ = answer.text
}

///|
async fn ask_question(m : @argparse.Matches) -> String {
  match values_of(m, "input-file") {
    [path, ..] => {
      let bytes = @fs.read_file(path).binary()
      @utf8.decode(bytes)
    }
    _ => join_values(m, "question")
  }
}

///|
async fn run_conversation_cmd(
  m : @argparse.Matches,
  terminal_ui : Bool,
) -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    let command = if terminal_ui { "tui" } else { "chat" }
    @stdio.stderr.write(
      "error: set MOONSAGE_API_KEY before using " + command + "\n",
    ) catch {
      _ => ()
    }
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let provider = @ai.provider_from_string(
    @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
  )
  let cwd = @env.current_dir().unwrap_or(".")
  let session_id = match values_of(m, "session") {
    [id, ..] => Some(id)
    _ => None
  }
  let continue_latest = flag_of(m, "continue")
  if terminal_ui {
    @tui.run_tui(
      key,
      base_url,
      model,
      cwd,
      session_id,
      continue_latest,
      provider~,
    )
  } else {
    @chat.run_chat(
      key,
      base_url,
      model,
      cwd,
      session_id,
      continue_latest,
      provider~,
    )
  }
}

///|
// Make the Windows console interpret output as UTF-8. No-op elsewhere.
#cfg(platform="windows")
extern "C" fn set_console_output_cp_utf8() = "moonsage_set_console_utf8"

///|
#cfg(platform="windows")
fn enable_utf8_console() -> Unit {
  set_console_output_cp_utf8()
}

///|
#cfg(not(platform="windows"))
fn enable_utf8_console() -> Unit {
  ()
}

///|
async fn main {
  enable_utf8_console()
  @dotenv.load_dotenv(".env")
  let args = normalize_mode_one_args(cli_args())
  let matches = root_command().parse(argv=args[1:]) catch {
    error => {
      @stdio.stderr.write("error: \{error.to_string()}\n") catch {
        _ => ()
      }
      abort("")
    }
  }
  if flag_of(matches, "version") {
    println("moonsage \{MOONSAGE_VERSION}")
    return
  }
  match matches.subcommand {
    Some(("chat", m)) => run_conversation_cmd(m, false)
    Some(("tui", m)) => run_conversation_cmd(m, true)
    Some(("search", m)) => run_search(join_values(m, "keywords"))
    Some(("ask", m)) =>
      run_ask(ask_question(m), stream_json=flag_of(m, "stream-json"))
    Some(("task", m)) => run_task(m)
    Some(("audit", m)) => @audit.run_audit(audit_args(m))
    Some(("batch-audit", m)) => run_batch_audit_command(m)
    _ => println(usage())
  }
}
