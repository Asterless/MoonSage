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
    #|create_pr accepts an optional branch name; if the default
    #|moonsage/fix-<repo> already exists on the remote, pass a new branch
    #|name. Re-running create_pr after a failed push reuses the local commits.
    #|The local project root is:
    #|
  ) +
  cwd +
  (
    #|
    #|All file tools (list_project_files, read_file, write_file, multi_edit,
    #|remove, git_diff, run_moon) operate on the current workspace root and
    #|use paths relative to it. clone_repo switches the workspace root to the
    #|clone; after that use plain relative paths like README.md, never paths
    #|starting with .moonsage/workspaces/.
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
  ws : @editing.Workspace,
) -> @agent.Agent {
  {
    system_prompt: chat_system_prompt(cwd),
    tools: @agent.ask_tools(modules) +
    @local.local_tools(ws) +
    @editing.write_tools(ws, @editing.Prompt) +
    @editing.publish_tools(ws),
    max_tool_calls: 30,
    max_rounds: 10,
    max_tokens: 6000,
  }
}

///|
// 恢复会话时还原工作区根目录；克隆目录已不存在则回退到项目根。
async fn restore_ws_root(
  ws : @editing.Workspace,
  saved_root : String,
  fallback : String,
) -> Unit {
  if saved_root == "" {
    return
  }
  if @editing.dir_exists(saved_root) {
    ws.set_root(saved_root)
  } else {
    println("! 工作区 \{saved_root} 已不存在，回到 \{fallback}")
  }
}

///|
priv enum ChatCommand {
  Exit
  Clear
  Help
  Prompt
  Undo
}

///|
fn slash_command(input : String) -> ChatCommand {
  match input {
    "/exit" | "/quit" | "exit" | "quit" => Exit
    "/clear" => Clear
    "/help" => Help
    "/undo" => Undo
    _ => Prompt
  }
}

///|
fn help_text() -> String {
  (
    #|Commands:
    #|  /help          show this help
    #|  /clear         clear the conversation history
    #|  /undo          undo the last file edit
    #|  /exit, /quit   leave the chat (exit/quit also work)
    #|
    #|The agent can search Mooncakes packages, inspect and modify the local
    #|project, clone a GitHub repository (clone_repo) and open a pull request
    #|(create_pr). Type your message and press Enter.
  )
}

///|
// 工具事件的中文短标签，用于一行式状态提示。
fn tool_label(name : String) -> String {
  match name {
    "search_modules" => "搜索模块"
    "get_module_manifest" => "获取模块信息"
    "get_module_index" => "获取模块索引"
    "get_package_docs" => "获取包文档"
    "list_project_files" => "列出文件"
    "read_file" => "读取文件"
    "run_moon" => "运行 moon"
    "git_diff" => "查看差异"
    "write_file" => "写入文件"
    "multi_edit" => "批量编辑"
    "remove" => "删除文件"
    "clone_repo" => "克隆仓库"
    "create_pr" => "创建 PR"
    _ => name
  }
}

///|
// 把 Failure(...)@moonsage FAILED: 前缀剥掉，只留人话错误信息。
fn prettify_error(message : String) -> String {
  let parts = message.split("FAILED: ").to_array()
  if parts.length() > 1 {
    let raw = parts[parts.length() - 1].to_owned()
    if raw.has_suffix(")") {
      raw[:raw.length() - 1].to_owned()
    } else {
      raw
    }
  } else {
    message
  }
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
    _ => {
      println("! 无法获取 Mooncakes 模块索引（继续本地模式）")
      []
    }
  }
  let ws = @editing.Workspace::new(cwd)
  let agent = chat_agent(modules, cwd, ws)
  let store_root = session_root(cwd)
  let fresh_session = fn() -> (String, @agent.Session) {
    (
      generated_session_id(@env.now().reinterpret_as_int64()),
      agent.new_session(),
    )
  }
  let resolved = match session_id {
    Some(id) =>
      match load_session_with_root(store_root, id) {
        Some(saved) => {
          restore_ws_root(ws, saved.ws_root, cwd)
          (id, saved.session)
        }
        None => {
          println("! 会话 \{id} 不存在，已开启新对话")
          fresh_session()
        }
      }
    None if continue_latest =>
      match latest_session_id(store_root) {
        Some(id) =>
          match load_session_with_root(store_root, id) {
            Some(saved) => {
              restore_ws_root(ws, saved.ws_root, cwd)
              (id, saved.session)
            }
            None => fresh_session()
          }
        None => fresh_session()
      }
    _ => fresh_session()
  }
  let mut current_id = resolved.0
  let mut session = resolved.1
  let reader = LineReader::new()
  println(
    "MoonSage chat · 会话 \{current_id} — /help 查看命令，/exit 或 /quit 退出",
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
            ws.set_root(cwd)
            println("已清空对话 · 会话 \{current_id}")
            continue
          }
          Help => {
            println(help_text())
            continue
          }
          Undo => {
            let message = ws.undo()
            println(message)
            save_session(store_root, current_id, session, ws.get_root())
            continue
          }
          Prompt => {
            // 上下文过长时先压缩再回答。
            if session.char_count() > compact_threshold_chars {
              @stdio.stdout.write("⋯ 正在压缩对话历史…\n")
              agent.compact(session, api_key, base_url, model) catch {
                _ =>
                  @stdio.stdout.write(
                    "! 上下文压缩失败，继续使用原历史\n",
                  )
              }
              save_session(store_root, current_id, session, ws.get_root())
            }
            let printer = @md_ansi.MdStreamPrinter::new()
            let mut answer_started = false
            let _ = agent.turn(
              session,
              api_key,
              base_url,
              model,
              input,
              on_delta=async fn(text) {
                if !answer_started {
                  answer_started = true
                  @stdio.stdout.write("\n")
                }
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
                    @stdio.stdout.write("\n▸ \{tool_label(name)} …\n")
                  @agent.ToolResult(_) => ()
                  _ => ()
                }
              },
            ) catch {
              e => {
                @stdio.stdout.write("✗ \{prettify_error(e.to_string())}\n")
                continue
              }
            }
            printer.finish()
            @stdio.stdout.write(printer.take_output())
            @stdio.stdout.write("\n")
            save_session(store_root, current_id, session, ws.get_root())
          }
        }
      }
    }
  }
}
