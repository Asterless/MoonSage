///|
fn chat_system_prompt(cwd : String) -> String {
  (
    #|You are MoonSage, an interactive agent for the MoonBit ecosystem.
    #|You can search Mooncakes packages with search_modules, and inspect the
    #|local project read-only with list_project_files, read_file, run_moon and
    #|git_diff (never modify files - no write tools are available).
    #|The local project root is:
    #|
  ) +
  cwd +
  (
    #|
    #|
    #|Rules:
    #|- Search before recommending packages; cite https://mooncakes.io/docs/<owner>/<module>.
    #|- Never invent package facts or API usage; inspect manifests and docs
    #|  before making claims about versions, APIs or build status.
    #|- Inspect the local project only when the question is about it; run
    #|  `moon build` / `moon test` to answer build or test questions.
    #|- Conserve tool calls: never repeat a tool with the same arguments, and
    #|  stop calling tools once you have enough evidence.
    #|- Answer in the user's language with Markdown.
  )
}

///|
fn chat_agent(
  modules : Array[@moonsage.ModuleSummary],
  cwd : String,
) -> @agent.Agent {
  {
    system_prompt: chat_system_prompt(cwd),
    tools: @agent.ask_tools(modules) + @local.local_tools(cwd),
    max_tool_calls: 12,
    max_rounds: 6,
    max_tokens: 1500,
  }
}

///|
priv enum ChatCommand {
  Exit
  Clear
  Help
  Prompt
}

///|
fn slash_command(input : String) -> ChatCommand {
  match input {
    "/exit" | "/quit" | "exit" | "quit" => Exit
    "/clear" => Clear
    "/help" => Help
    _ => Prompt
  }
}

///|
fn help_text() -> String {
  (
    #|Commands:
    #|  /help          show this help
    #|  /clear         clear the conversation history
    #|  /exit, /quit   leave the chat (exit/quit also work)
    #|
    #|The agent can search Mooncakes packages and inspect the local project
    #|read-only. Type your message and press Enter.
  )
}

///|
pub async fn run_chat(
  api_key : String,
  base_url : String,
  model : String,
  cwd : String,
) -> Unit {
  let modules = @mooncakes.fetch_modules() catch {
    e => {
      println("warning: failed to fetch Mooncakes modules: \{e.to_string()}")
      []
    }
  }
  let agent = chat_agent(modules, cwd)
  let mut session = agent.new_session()
  println("MoonSage chat — /help for commands, /exit or /quit to leave")
  for ;; {
    @stdio.stdout.write("moon> ")
    match @stdio.stdin.read_until("\n") {
      None => {
        @stdio.stdout.write("\n")
        return
      }
      Some(line) => {
        let input = line.trim().to_owned()
        if input == "" {
          continue
        }
        match slash_command(input) {
          Exit => return
          Clear => {
            session = agent.new_session()
            println("conversation cleared")
            continue
          }
          Help => {
            println(help_text())
            continue
          }
          Prompt => {
            let printer = @md_ansi.MdStreamPrinter::new()
            let answer = agent.turn(session, api_key, base_url, model, input, on_delta=async fn(
              text,
            ) {
              printer.feed(text)
              let out = printer.take_output()
              if out != "" {
                @stdio.stdout.write(out)
              }
            }) catch {
              e => {
                @stdio.stdout.write("\nerror: \{e.to_string()}\n")
                continue
              }
            }
            printer.finish()
            @stdio.stdout.write(printer.take_output())
            @stdio.stdout.write("\n")
            for event in answer.trace {
              println(event)
            }
          }
        }
      }
    }
  }
}
