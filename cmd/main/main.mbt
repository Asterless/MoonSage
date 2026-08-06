///|
fn usage() -> String {
  (
    #|MoonSage - an agent for the MoonBit package ecosystem
    #|
    #|Usage:
    #|  moonsage chat
    #|  moonsage search <keywords>
    #|  moonsage ask <question>
    #|  moonsage audit <owner/module> [--fix] [--confirm prompt|diff|yes] [--workspace <dir>] [--max-calls <n>]
    #|  moonsage audit --clean
    #|
    #|Run `moonsage --help` for the full option reference.
    #|
    #|Environment:
    #|  MOONSAGE_API_KEY    required for chat/ask/audit
    #|  MOONSAGE_BASE_URL   default: https://api.deepseek.com
    #|  MOONSAGE_MODEL      default: deepseek-chat
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
  let answer = @moonsage.run_search_agent(modules, query)
  println(@moonsage.render_search_answer(answer))
}

///|
async fn run_ask(question : String) -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    println("error: set MOONSAGE_API_KEY before using ask")
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let modules = @mooncakes.fetch_modules()
  @stdio.stdout.write("MoonSage\n")
  let printer = @md_ansi.MdStreamPrinter::new()
  let answer = @agent.run_llm_agent(key, base_url, model, modules, question, on_delta=async fn(
    text,
  ) {
    printer.feed(text)
    let out = printer.take_output()
    if out != "" {
      @stdio.stdout.write(out)
    }
  })
  printer.finish()
  @stdio.stdout.write(printer.take_output())
  @stdio.stdout.write("\n")
  for event in answer.trace {
    println(event)
  }
  let _ = answer.text
}

///|
async fn run_chat_cmd() -> Unit {
  let key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
  guard key != "" else {
    println("error: set MOONSAGE_API_KEY before using chat")
    return
  }
  let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
  let cwd = @env.current_dir().unwrap_or(".")
  @chat.run_chat(key, base_url, model, cwd)
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
  let args = cli_args()
  let matches = root_command().parse(argv=args[1:]) catch {
    error => {
      @stdio.stderr.write("error: \{error.to_string()}\n") catch {
        _ => ()
      }
      return
    }
  }
  match matches.subcommand {
    Some(("chat", _)) => run_chat_cmd()
    Some(("search", m)) => run_search(join_values(m, "keywords"))
    Some(("ask", m)) => run_ask(join_values(m, "question"))
    Some(("audit", m)) => @audit.run_audit(audit_args(m))
    _ => println(usage())
  }
}
