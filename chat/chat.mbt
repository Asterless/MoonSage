///|
// 会话历史超过该字符数时触发一次上下文压缩。
let compact_threshold_chars = 20000

///|
fn chat_system_prompt(cwd : String) -> String {
  (
    #|You are MoonSage, an interactive agent for the MoonBit ecosystem.
    #|You can search Mooncakes packages with search_modules, and inspect the
    #|local project read-only with list_project_files, read_file, run_moon and
    #|git_diff. You can also modify the local project with write_file,
    #|multi_edit and remove; every change asks the user to confirm (y/N)
    #|before it is applied, and changed source files must pass syntax checks.
    #|Use clone_repo to work on a GitHub repository (all file tools switch to
    #|the clone), and create_pr to publish your changes as a pull request.
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
  let ws = @editing.Workspace::new(cwd)
  {
    system_prompt: chat_system_prompt(cwd),
    tools: @agent.ask_tools(modules) +
    @local.local_tools(ws) +
    @editing.write_tools(ws, @editing.Prompt) +
    @editing.publish_tools(ws),
    max_tool_calls: 12,
    max_rounds: 6,
    max_tokens: 4000,
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
#borrow(bytes)
extern "C" fn gbk_bytes_to_utf8(
  bytes : Bytes,
  offset : Int,
  len : Int,
) -> Bytes = "moonsage_gbk_to_utf8"

///|
// 优先按 UTF-8 解码；失败（中文 Windows 控制台默认是 GBK 输入）时调用
// C stub 用系统代码页转成 UTF-8。同时剥离前导 UTF-8 BOM（部分终端/管道
// 会在输入前附加 EF BB BF），保证中文输入既不会崩溃也不会乱码。
fn utf8_or_gbk(bytes : Bytes, end : Int) -> String {
  let start = if end >= 3 &&
    bytes[0] == b'\xef' &&
    bytes[1] == b'\xbb' &&
    bytes[2] == b'\xbf' {
    3
  } else {
    0
  }
  @utf8.decode(bytes[start:end]) catch {
    _ => {
      let converted = gbk_bytes_to_utf8(bytes, start, end - start)
      @utf8.decode(converted[0:converted.length()]) catch {
        _ => converted.to_unchecked_string()
      }
    }
  }
}

///|
// 带持久缓冲的行读取器：一次 read_some 可能返回多行（粘贴/管道），
// `\n` 之后的剩余字节必须保留给下一轮，否则对话会在中途丢输入并退出。
priv struct LineReader {
  pending : Buffer
}

///|
fn LineReader::new() -> LineReader {
  { pending: Buffer() }
}

///|
async fn LineReader::next(self : LineReader) -> String? {
  for ;; {
    let bytes = self.pending.to_bytes()
    let len = bytes.length()
    let mut found = -1
    for i = 0; i < len; i = i + 1 {
      if bytes[i] == b'\n' {
        found = i
        break
      }
    }
    if found >= 0 {
      let line = utf8_or_gbk(bytes, found)
      self.pending.reset()
      if found + 1 < len {
        self.pending.write_bytes(bytes[found + 1:])
      }
      return Some(line)
    }
    match @stdio.stdin.read_some() {
      None => {
        if len == 0 {
          return None
        }
        let line = utf8_or_gbk(bytes, len)
        self.pending.reset()
        return Some(line)
      }
      Some(chunk) => self.pending.write_bytes(chunk)
    }
  }
}

///|
pub async fn run_chat(
  api_key : String,
  base_url : String,
  model : String,
  cwd : String,
  session_id : String?,
  continue_latest : Bool,
) -> Unit {
  let modules = @mooncakes.fetch_modules() catch {
    e => {
      println("warning: failed to fetch Mooncakes modules: \{e.to_string()}")
      []
    }
  }
  let agent = chat_agent(modules, cwd)
  let store_root = session_root(cwd)
  let fresh_session = fn() -> (String, @agent.Session) {
    (
      generated_session_id(@env.now().reinterpret_as_int64()),
      agent.new_session(),
    )
  }
  let resolved = match session_id {
    Some(id) =>
      match load_session(store_root, id) {
        Some(saved) => (id, saved)
        None => {
          println(
            "warning: session \{id} not found; starting a new conversation",
          )
          fresh_session()
        }
      }
    None if continue_latest =>
      match latest_session_id(store_root) {
        Some(id) => {
          let saved = load_session(store_root, id).unwrap_or(
            agent.new_session(),
          )
          (id, saved)
        }
        None => fresh_session()
      }
    _ => fresh_session()
  }
  let mut current_id = resolved.0
  let mut session = resolved.1
  let reader = LineReader::new()
  println(
    "MoonSage chat · session \{current_id} — /help for commands, /exit or /quit to leave",
  )
  for ;; {
    @stdio.stdout.write("moon> ")
    match reader.next() {
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
            let (new_id, new_session) = fresh_session()
            current_id = new_id
            session = new_session
            println("conversation cleared · session \{current_id}")
            continue
          }
          Help => {
            println(help_text())
            continue
          }
          Prompt => {
            // 上下文过长时先压缩再回答。
            if session.char_count() > compact_threshold_chars {
              @stdio.stdout.write("[compacting conversation...]\n")
              agent.compact(session, api_key, base_url, model) catch {
                e =>
                  @stdio.stdout.write(
                    "\n[compaction failed: \{e.to_string()}]\n",
                  )
              }
              save_session(store_root, current_id, session)
            }
            let printer = @md_ansi.MdStreamPrinter::new()
            let _ = agent.turn(
              session,
              api_key,
              base_url,
              model,
              input,
              on_delta=async fn(text) {
                printer.feed(text)
                printer.flush_partial()
                let out = printer.take_output()
                if out != "" {
                  @stdio.stdout.write(out)
                }
              },
              on_event=async fn(event) {
                match event {
                  @agent.ToolCall(name) =>
                    @stdio.stdout.write("\n[tool] \{name} ...\n")
                  @agent.ToolResult(name) =>
                    @stdio.stdout.write("[observation] \{name} completed\n")
                  _ => ()
                }
              },
            ) catch {
              e => {
                @stdio.stdout.write("\nerror: \{e.to_string()}\n")
                continue
              }
            }
            printer.finish()
            @stdio.stdout.write(printer.take_output())
            @stdio.stdout.write("\n")
            save_session(store_root, current_id, session)
          }
        }
      }
    }
  }
}
