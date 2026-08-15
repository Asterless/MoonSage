///|
/// Interactive input shown at the bottom of the normal terminal screen.
/// Completed conversation output remains in the terminal's native scrollback.
priv struct ChatComposer {
  mut width : Int
  input : @input.TextInputController
  mut selected_command : Int
  mut drawn_lines : Int
  mut runtime_status : String
}

///|
let compact_threshold_tokens = 8000

///|
let chat_context_window_tokens = 32768

///|
let chat_reserved_output_tokens = 6000

///|
let moonsage_logo : String =
  #|    __  ______  ____  _   _______ ___   ____________
  #|   /  |/  / __ \/ __ \/ | / / ___//   | / ____/ ____/
  #|  / /|_/ / / / / / / /  |/ /\__ \/ /| |/ / __/ __/
  #| / /  / / /_/ / /_/ / /|  /___/ / ___ / /_/ / /___
  #|/_/  /_/\____/\____/_/ |_//____/_/  |_\____/_____/

///|
let chat_commands : Array[(String, String)] = [
  ("/help", "Show available commands"),
  ("/status", "Show session and runtime details"),
  ("/context", "Show context window usage"),
  ("/compact", "Summarize older conversation history"),
  ("/tools", "List tools available to the agent"),
  ("/diff", "Show current workspace changes"),
  ("/model", "Show active model and provider"),
  ("/cwd", "Show active workspace directory"),
  ("/new", "Start a new conversation"),
  ("/undo", "Undo the last file edit"),
  ("/exit", "Leave MoonSage"),
]

///|
priv enum TuiCommand {
  Exit
  Clear
  Help
  Undo
  Status
  Context
  Compact
  Tools
  Diff
  Model
  Cwd
  Prompt
}

///|
fn slash_command(input : String) -> TuiCommand {
  match input {
    "/exit" | "/quit" | "exit" | "quit" => Exit
    "/clear" | "/new" => Clear
    "/" | "/help" => Help
    "/undo" => Undo
    "/status" => Status
    "/context" => Context
    "/compact" => Compact
    "/tools" => Tools
    "/diff" => Diff
    "/model" => Model
    "/cwd" => Cwd
    _ => Prompt
  }
}

///|
fn help_text() -> String {
  (
    #|Commands:
    #|  /, /help       show this command menu
    #|  /status        show session and runtime information
    #|  /context       show estimated context usage
    #|  /compact       summarize older conversation history
    #|  /tools         list tools available to the agent
    #|  /diff          show current workspace changes
    #|  /model         show the active model and provider
    #|  /cwd           show the active workspace directory
    #|  /new, /clear   start a new conversation
    #|  /undo          undo the last file edit
    #|  /exit, /quit   leave the TUI
  )
}

///|
fn context_percent(tokens : Int) -> Int {
  (tokens * 100 / chat_context_window_tokens).clamp(min=0, max=100)
}

///|
fn context_bar(tokens : Int, width? : Int = 16) -> String {
  let filled = (context_percent(tokens) * width / 100).clamp(min=0, max=width)
  "#".repeat(filled) + "-".repeat(width - filled)
}

///|
fn context_text(session : @runtime.Session) -> String {
  let tokens = session.estimated_tokens()
  "Context  [" +
  context_bar(tokens) +
  "] " +
  tokens.to_string() +
  " / " +
  chat_context_window_tokens.to_string() +
  " estimated tokens (" +
  context_percent(tokens).to_string() +
  "%)"
}

///|
fn chat_status_text(
  model : String,
  provider : @llm.ProviderKind,
  session_id : String,
  workspace : String,
  session : @runtime.Session,
) -> String {
  "Model      " +
  model +
  "\nProvider   " +
  @llm.provider_to_string(provider) +
  "\nSession    " +
  session_id +
  "\nWorkspace  " +
  workspace +
  "\n" +
  context_text(session) +
  "\nEdits      confirmation required"
}

///|
fn agent_tools_text(agent : @runtime.Agent) -> String {
  let out = StringBuilder::new()
  out.write_string(
    "Available tools (" + agent.tools.length().to_string() + "):\n",
  )
  for tool in agent.tools {
    out.write_string(
      "  " + tool.schema.name + "  " + tool.schema.description + "\n",
    )
  }
  out.to_string().trim_end().to_owned()
}

///|
async fn restore_workspace_root(
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
    println("! Workspace \{saved_root} no longer exists; using \{fallback}")
  }
}

///|
fn ChatComposer::new(width : Int) -> ChatComposer {
  let input_width = (width - 3).max(1)
  {
    width,
    input: @input.TextInputController::new(
      @input.TextInputConfig::new(input_width, 1),
      "",
    ),
    selected_command: 0,
    drawn_lines: 0,
    runtime_status: "Ready",
  }
}

///|
fn ChatComposer::set_runtime_status(
  self : ChatComposer,
  model : String,
  provider : @llm.ProviderKind,
  session_id : String,
  session : @runtime.Session,
) -> Unit {
  let tokens = session.estimated_tokens()
  self.runtime_status = model +
    "  ·  " +
    @llm.provider_to_string(provider) +
    "  ·  context " +
    context_percent(tokens).to_string() +
    "%  ·  " +
    session_id
}

///|
fn ChatComposer::resize(self : ChatComposer, width : Int) -> Unit {
  self.width = width
  self.input.resize((width - 3).max(1), 1)
}

///|
fn ChatComposer::command_suggestions(
  self : ChatComposer,
) -> Array[(String, String)] {
  let query = self.input.get_text()
  if !query.has_prefix("/") || query.contains(" ") {
    return []
  }
  chat_commands.filter(fn(item) { item.0.has_prefix(query) })
}

///|
fn ChatComposer::sync_selection(self : ChatComposer) -> Unit {
  let count = self.command_suggestions().length()
  if count == 0 {
    self.selected_command = 0
  } else {
    self.selected_command = self.selected_command.clamp(min=0, max=count - 1)
  }
}

///|
fn take_display_width(text : String, max_width : Int) -> String {
  let out = StringBuilder::new()
  let mut width = 0
  for char in text {
    let next = @core.char_display_width(char)
    if width + next > max_width {
      break
    }
    out.write_char(char)
    width += next
  }
  out.to_string()
}

///|
fn startup_info(
  width : Int,
  model : String,
  provider : @llm.ProviderKind,
  session_id : String,
  workspace : String,
  session : @runtime.Session,
) -> String {
  let max_width = (width - 1).max(1)
  let lines = [
    "Model      " + model + " (" + @llm.provider_to_string(provider) + ")",
    "Session    " + session_id,
    "Workspace  " + workspace,
    context_text(session),
    "Permissions  confirm file edits",
  ]
  let out = StringBuilder::new()
  for line in lines {
    out.write_string(
      "\u001b[90m" + take_display_width(line, max_width) + "\u001b[0m\n",
    )
  }
  out.to_string()
}

///|
fn ChatComposer::visible_input(self : ChatComposer) -> String {
  let state = self.input.get_display_state()
  if state.lines.length() == 0 {
    ""
  } else {
    String::from_array(state.lines[state.scroll_offset].chars)
  }
}

///|
fn ChatComposer::cursor_column(self : ChatComposer) -> Int {
  // The input controller uses the same wrapped line and display-width
  // calculation for rendering and cursor placement.
  3 + self.input.get_display_state().cursor_col
}

///|
fn ChatComposer::frame_lines(self : ChatComposer) -> Array[String] {
  let lines : Array[String] = [
    "\u001b[90m" +
    take_display_width(self.runtime_status, (self.width - 1).max(1)) +
    "\u001b[0m",
  ]
  let suggestions = self.command_suggestions()
  let menu_start = if self.selected_command < 8 {
    0
  } else {
    self.selected_command - 7
  }
  let menu_end = (menu_start + 8).min(suggestions.length())
  for i = menu_start; i < menu_end; i = i + 1 {
    let item = suggestions[i]
    let marker = if i == self.selected_command { ">" } else { " " }
    let name = marker + " " + item.0
    let padding = (14 - @core.string_display_width(name)).max(1)
    let line = name + " ".repeat(padding) + item.1
    let style = if i == self.selected_command {
      "\u001b[36;1m"
    } else {
      "\u001b[90m"
    }
    lines.push(
      style + take_display_width(line, (self.width - 1).max(1)) + "\u001b[0m",
    )
  }
  if suggestions.length() > 8 {
    let more = "  " +
      (suggestions.length() - 8).to_string() +
      " more commands  ·  ↑↓ to navigate"
    lines.push(
      "\u001b[90m" +
      take_display_width(more, (self.width - 1).max(1)) +
      "\u001b[0m",
    )
  }
  let input = take_display_width(self.visible_input(), (self.width - 3).max(1))
  lines.push("\u001b[36;1m>\u001b[0m  " + input)
  lines
}

///|
fn cursor_up(lines : Int) -> String {
  if lines > 0 {
    "\u001b[" + lines.to_string() + "A"
  } else {
    ""
  }
}

///|
fn ChatComposer::clear_frame(self : ChatComposer) -> String {
  if self.drawn_lines == 0 {
    return ""
  }
  let out = StringBuilder::new()
  out.write_string("\u001b[?25l\r")
  out.write_string(cursor_up(self.drawn_lines - 1))
  for i = 0; i < self.drawn_lines; i = i + 1 {
    out.write_string("\u001b[2K")
    if i + 1 < self.drawn_lines {
      out.write_string("\u001b[1B\r")
    }
  }
  out.write_string(cursor_up(self.drawn_lines - 1))
  out.write_string("\r")
  self.drawn_lines = 0
  out.to_string()
}

///|
fn ChatComposer::draw_frame(self : ChatComposer) -> String {
  let out = StringBuilder::new()
  out.write_string(self.clear_frame())
  let lines = self.frame_lines()
  for i, line in lines {
    out.write_string(line)
    if i + 1 < lines.length() {
      out.write_string("\r\n")
    }
  }
  out.write_string("\r")
  let col = self.cursor_column()
  if col > 1 {
    out.write_string("\u001b[" + (col - 1).to_string() + "C")
  }
  out.write_string("\u001b[?25h")
  self.drawn_lines = lines.length()
  out.to_string()
}

///|
priv enum ChatInputOutcome {
  Changed
  Submit
  Quit
  Ignored
}

///|
fn ChatComposer::handle_input(
  self : ChatComposer,
  raw : String,
) -> ChatInputOutcome {
  if raw == "" {
    return Ignored
  }
  if @termui.is_printable_string(raw) {
    ignore(self.input.apply_action(@input.EditAction::Insert(raw)))
    self.sync_selection()
    return Changed
  }
  let event = @termui.parse_input(raw)
  match event {
    @termui.InputEvent::Key(key) => {
      let suggestions = self.command_suggestions()
      match key {
        @termui.KeyEvent::Special(@termui.SpecialKey::Up, _) if suggestions.length() >
          0 => {
          self.selected_command = if self.selected_command == 0 {
            suggestions.length() - 1
          } else {
            self.selected_command - 1
          }
          Changed
        }
        @termui.KeyEvent::Special(@termui.SpecialKey::Down, _) if suggestions.length() >
          0 => {
          self.selected_command = (self.selected_command + 1) %
            suggestions.length()
          Changed
        }
        @termui.KeyEvent::Special(@termui.SpecialKey::Tab, _) if suggestions.length() >
          0 => {
          self.input.set_text(suggestions[self.selected_command].0)
          self.input.set_cursor_pos(self.input.get_text().length())
          self.sync_selection()
          Changed
        }
        @termui.KeyEvent::Special(@termui.SpecialKey::Enter, _) if suggestions.length() >
          0 => {
          self.input.set_text(suggestions[self.selected_command].0)
          Submit
        }
        _ => {
          let config = @input.TextInputConfig::new((self.width - 3).max(1), 1)
          match @input.interpret_key(key, config) {
            @input.EditAction::Confirm => Submit
            @input.EditAction::ForceQuit => Quit
            @input.EditAction::Cancel => {
              self.input.set_text("")
              self.sync_selection()
              Changed
            }
            @input.EditAction::None => Ignored
            action => {
              ignore(self.input.apply_action(action))
              self.sync_selection()
              Changed
            }
          }
        }
      }
    }
    _ => Ignored
  }
}

///|
#cfg(platform="windows")
extern "C" fn windows_tui_input_start() -> Int = "moonsage_tui_input_start"

///|
#cfg(platform="windows")
extern "C" fn windows_tui_input_stop() = "moonsage_tui_input_stop"

///|
#cfg(platform="windows")
extern "C" fn windows_tui_read_event() -> String = "moonsage_tui_read_event"

///|
#cfg(platform="windows")
fn start_chat_input() -> Bool {
  windows_tui_input_start() == 0
}

///|
#cfg(platform="windows")
fn stop_chat_input() -> Unit {
  windows_tui_input_stop()
}

///|
#cfg(platform="windows")
async fn read_chat_input() -> String {
  @async.sleep(0)
  windows_tui_read_event()
}

///|
#cfg(not(platform="windows"))
fn start_chat_input() -> Bool {
  @termui.enable_raw_mode()
  true
}

///|
#cfg(not(platform="windows"))
fn stop_chat_input() -> Unit {
  @termui.cleanup_stdin()
}

///|
#cfg(not(platform="windows"))
async fn read_chat_input() -> String {
  for ;; {
    let key = @termui.read_key()
    if key != "" {
      return key
    }
    @async.sleep(10)
  }
}

///|
fn finish_chat_input(composer : ChatComposer) -> Unit {
  @termui.print_raw(composer.clear_frame())
  stop_chat_input()
  @termui.print_raw("\u001b[?25h")
}

///|
pub async fn run_tui(
  api_key : String,
  base_url : String,
  model : String,
  cwd : String,
  session_id : String?,
  continue_latest : Bool,
  provider? : @llm.ProviderKind = OpenAi,
) -> Unit {
  let modules = @mooncakes.fetch_modules() catch {
    _ => {
      println(
        "! Unable to fetch the Mooncakes module index; continuing locally",
      )
      []
    }
  }
  let ws = @editing.Workspace::new(cwd)
  let project_instructions = @project.load_project_instructions(cwd)
  let agent = @chat.create_agent(modules, cwd, ws, project_instructions~)
  let store_root = @chat.session_root(cwd)
  let fresh_session = fn() -> (String, @runtime.Session) {
    (
      @chat.generated_session_id(@env.now().reinterpret_as_int64()),
      agent.new_session(),
    )
  }
  let resolved = match session_id {
    Some(id) =>
      match @chat.load_session_with_root(store_root, id) {
        Some(saved) => {
          restore_workspace_root(ws, saved.ws_root, cwd)
          (id, saved.session)
        }
        None => {
          println("! Session \{id} does not exist; starting a new conversation")
          fresh_session()
        }
      }
    None if continue_latest =>
      match @chat.latest_session_id(store_root) {
        Some(id) =>
          match @chat.load_session_with_root(store_root, id) {
            Some(saved) => {
              restore_workspace_root(ws, saved.ws_root, cwd)
              (id, saved.session)
            }
            None => fresh_session()
          }
        None => fresh_session()
      }
    _ => fresh_session()
  }
  run_tui_session(
    api_key,
    base_url,
    model,
    cwd,
    ws,
    agent,
    store_root,
    resolved.0,
    resolved.1,
    fresh_session,
    provider,
  )
}

///|
async fn run_tui_session(
  api_key : String,
  base_url : String,
  model : String,
  cwd : String,
  ws : @editing.Workspace,
  agent : @runtime.Agent,
  store_root : String,
  initial_id : String,
  initial_session : @runtime.Session,
  fresh_session : () -> (String, @runtime.Session),
  provider : @llm.ProviderKind,
) -> Unit {
  let client = @llm_adapter.client(api_key, base_url, model, provider)
  let (width, _) = @termui.get_terminal_size()
  let composer = ChatComposer::new(width)
  let mut current_id = initial_id
  let mut session = initial_session
  let mut running = true
  composer.set_runtime_status(model, provider, current_id, session)
  if width >= 62 {
    @termui.print_raw("\u001b[36;1m" + moonsage_logo + "\u001b[0m\n")
  } else {
    @termui.print_raw("\u001b[36;1mMOONSAGE\u001b[0m\n")
  }
  @termui.print_raw("\u001b[90mMOONBIT ECOSYSTEM AGENT\u001b[0m\n")
  @termui.print_raw(
    startup_info(width, model, provider, current_id, ws.get_root(), session),
  )
  guard start_chat_input() else {
    @termui.print_raw(
      "Unable to initialize interactive input. Run MoonSage in a terminal, or use `moonsage chat` for redirected input.\n",
    )
    return
  }
  @termui.print_raw(composer.draw_frame())
  try {
    while running {
      let raw = read_chat_input()
      let (next_width, _) = @termui.get_terminal_size()
      if next_width != composer.width {
        composer.resize(next_width)
      }
      match composer.handle_input(raw) {
        Quit => running = false
        Ignored => ()
        Changed => @termui.print_raw(composer.draw_frame())
        Submit => {
          let input = composer.input.get_text().trim().to_owned()
          composer.input.set_text("")
          composer.selected_command = 0
          @termui.print_raw(composer.clear_frame())
          if input == "" {
            @termui.print_raw("\u001b[90mType a message first\u001b[0m\n")
            @termui.print_raw(composer.draw_frame())
            continue
          }
          match slash_command(input) {
            Exit => running = false
            Clear => {
              let (new_id, new_session) = fresh_session()
              current_id = new_id
              session = new_session
              ws.set_root(cwd)
              @termui.print_raw(
                "\u001b[90mNew conversation  ·  Session " +
                current_id +
                "\u001b[0m\n",
              )
            }
            Help => @termui.print_raw(help_text() + "\n")
            Undo => {
              @termui.print_raw(ws.undo() + "\n")
              @chat.save_session(store_root, current_id, session, ws.get_root())
            }
            Status =>
              @termui.print_raw(
                chat_status_text(
                  model,
                  provider,
                  current_id,
                  ws.get_root(),
                  session,
                ) +
                "\n",
              )
            Context => @termui.print_raw(context_text(session) + "\n")
            Compact => {
              let before = session.estimated_tokens()
              if before < 256 {
                @termui.print_raw(
                  "Context is already compact (" +
                  before.to_string() +
                  " tokens)\n",
                )
              } else {
                try
                  agent.compact_session(
                    client,
                    session,
                    threshold_tokens=before - 1,
                  )
                catch {
                  e =>
                    @termui.print_raw(
                      "Compaction failed: " +
                      @chat.friendly_error(e.to_string()) +
                      "\n",
                    )
                } noraise {
                  _ => {
                    let after = session.estimated_tokens()
                    @termui.print_raw(
                      "Context compacted: " +
                      before.to_string() +
                      " -> " +
                      after.to_string() +
                      " estimated tokens\n",
                    )
                    @chat.save_session(
                      store_root,
                      current_id,
                      session,
                      ws.get_root(),
                    )
                  }
                }
              }
            }
            Tools => @termui.print_raw(agent_tools_text(agent) + "\n")
            Diff => {
              let diff = @local.git_diff(ws.get_root(), None) catch {
                e => "Unable to read diff: " + e.to_string()
              }
              if diff.trim() == "" {
                @termui.print_raw("Workspace has no tracked changes.\n")
              } else {
                @termui.print_raw(diff + "\n")
              }
            }
            Model =>
              @termui.print_raw(
                "Model     " +
                model +
                "\nProvider  " +
                @llm.provider_to_string(provider) +
                "\n",
              )
            Cwd => @termui.print_raw("Workspace  " + ws.get_root() + "\n")
            Prompt => {
              @termui.print_raw("\u001b[36;1m>\u001b[0m  " + input + "\n")
              if session.estimated_tokens() > compact_threshold_tokens {
                @termui.print_raw(
                  "\u001b[90mCompacting conversation…\u001b[0m\n",
                )
                agent.compact_session(client, session) catch {
                  _ =>
                    @termui.print_raw("Context compaction failed; continuing\n")
                }
                @chat.save_session(
                  store_root,
                  current_id,
                  session,
                  ws.get_root(),
                )
              }
              let printer = @md_ansi.MdStreamPrinter::new()
              let thinking = StringBuilder::new()
              let mut answer_started = false
              // Tool confirmations read canonical lines from stdin. Leave raw
              // mode while the agent may invoke a write or publish tool.
              stop_chat_input()
              try
                agent.execute_turn(
                  client,
                  session,
                  input,
                  context_window_tokens=chat_context_window_tokens,
                  reserved_output_tokens=chat_reserved_output_tokens,
                  on_event=fn(event) {
                    match event {
                      ThinkingDelta(event) =>
                        if event.text != "" &&
                          thinking.to_string().length() < 20000 {
                          thinking.write_string(event.text)
                        }
                      ToolStarted(event) => {
                        if !thinking.is_empty() {
                          @termui.print_raw(
                            "\u001b[90m" + thinking.to_string() + "\u001b[0m\n",
                          )
                          thinking.reset()
                        }
                        @termui.print_raw(
                          "\u001b[90mRunning " +
                          @chat.tool_display_name(event.name) +
                          "…\u001b[0m\n",
                        )
                      }
                      FinalDelta(text) => {
                        if !thinking.is_empty() {
                          @termui.print_raw(
                            "\u001b[90m" + thinking.to_string() + "\u001b[0m\n",
                          )
                          thinking.reset()
                        }
                        if !answer_started {
                          answer_started = true
                          @termui.print_raw("\u001b[36;1mMoonSage\u001b[0m\n")
                        }
                        printer.feed(text)
                        let out = printer.take_output()
                        if out != "" {
                          @termui.print_raw(out)
                        }
                      }
                      _ => ()
                    }
                  },
                )
              catch {
                e =>
                  @termui.print_raw(
                    "Error: " + @chat.friendly_error(e.to_string()) + "\n",
                  )
              } noraise {
                _ => ()
              }
              if !start_chat_input() {
                @termui.print_raw(
                  "Unable to restore interactive input; leaving the TUI.\n",
                )
                running = false
              }
              if !thinking.is_empty() {
                @termui.print_raw(
                  "\u001b[90m" + thinking.to_string() + "\u001b[0m\n",
                )
              }
              printer.finish()
              @termui.print_raw(printer.take_output() + "\n")
              @chat.save_session(store_root, current_id, session, ws.get_root())
            }
          }
          if running {
            composer.set_runtime_status(model, provider, current_id, session)
            @termui.print_raw(composer.draw_frame())
          }
        }
      }
    }
  } catch {
    e => {
      finish_chat_input(composer)
      raise e
    }
  }
  finish_chat_input(composer)
}
