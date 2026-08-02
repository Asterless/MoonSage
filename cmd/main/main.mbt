///|
fn usage() -> String {
  (
    #|MoonSage - an agent for the MoonBit package ecosystem
    #|
    #|Usage:
    #|  moon run cmd/main -- search <keywords>
    #|  moon run cmd/main -- ask <question>
    #|
    #|The ask command reads:
    #|  MOONSAGE_API_KEY    required
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
  let modules = fetch_modules()
  let answer = @moonsage.run_agent(modules, query)
  println(@moonsage.render_answer(answer))
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
  let modules = fetch_modules()
  println("MoonSage\n")
  let answer = run_llm_agent(key, base_url, model, modules, question, on_delta=async fn(
    text,
  ) {
    @stdio.stdout.write(text)
  })
  println("\n")
  for event in answer.trace {
    println(event)
  }
  let _ = answer.text
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
  let args = cli_args()
  if args.length() < 3 || args[1] == "--help" || args[1] == "-h" {
    println(usage())
    return
  }
  let command = args[1]
  let query = join_query(args, 2)
  match command {
    "search" => run_search(query)
    "ask" => run_ask(query)
    _ => println("Unknown command: \{command}\n\n\{usage()}")
  }
}
