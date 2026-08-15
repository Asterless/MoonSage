///|
using @rabbita {type Cmd, type Emit, type Html, type Val}

///|
using @html {
  aside,
  button,
  details,
  div,
  form,
  h1,
  header,
  input,
  li,
  main_,
  nav,
  p,
  pre,
  section,
  span,
  summary,
  textarea,
  ul,
}

///|
struct Message {
  role : String
  text : String
} derive(Debug, Eq)

///|
struct Session {
  id : String
  title : String
  detail : String
  messages : Array[Message]
} derive(Debug, Eq)

///|
// One in-flight agent request. Deltas land in answer_buf and are committed
// to answer_shown by the throttled AgentFlush tick, so streaming stays
// responsive without O(n^2) string rebuilds on every chunk.
struct Request {
  id : Int
  session_id : String
  prompt : String
  status : String
  answer_buf : Array[String]
  answer_shown : String
  thinking_buf : Array[String]
  thinking_shown : String
  flush_pending : Bool
  tools : Array[ToolCall]
  warning : String
  history_truncated : Bool
} derive(Eq)

///|
struct ToolCall {
  id : String
  name : String
  arguments : String
  status : String
  result : String
  round : Int
} derive(Eq)

///|
enum RequestState {
  Idle
  Sending(Request)
  Failed(Request, String)
} derive(Eq)

///|
struct Model {
  draft : String
  sessions : Array[Session]
  active_session : Int
  request : RequestState
  command_open : Bool
  sidebar_open : Bool
  workspace : WorkspaceModel
  next_id : Int
} derive(Eq)

///|
enum Msg {
  DraftChanged(String)
  UsePrompt(String)
  Submit
  CancelRequest
  AgentStatus(Int, String)
  AgentDelta(Int, String)
  AgentThinking(Int, String)
  AgentMeta(Int, Bool)
  AgentToolStarted(Int, String, String, String, Int)
  AgentToolFinished(Int, String, String, String)
  AgentRetry(Int, Int, String)
  AgentWarning(Int, String)
  AgentFlush(Int)
  AgentFinished(Int)
  AgentFailed(Int, String)
  AgentStopped(Int)
  Retry
  RunCommand(String)
  SelectSession(Int)
  ToggleSidebar
  NewSession
  ToggleWorkspace
  WorkspaceTabSelected(String)
  WorkspaceTreeReceived(String)
  WorkspaceFilterChanged(String)
  WorkspaceSelectFile(String)
  WorkspaceFileReceived(String, String)
  WorkspaceContentChanged(String)
  WorkspaceSaveFile
  WorkspaceFileSaved(String, String)
  WorkspaceStatusReceived(String)
  WorkspaceDiffScopeChanged(String)
  WorkspaceDiffReceived(String, String, String)
  WorkspaceRefresh
  WorkspaceStage(String)
  WorkspaceUnstage(String)
  WorkspaceGitActionReceived(String, String)
  WorkspaceCommitMessageChanged(String)
  WorkspaceCommit
  WorkspaceCommitReceived(String)
  WorkspaceFailed(String)
} derive(Eq)

///|
let commands : Array[(String, String)] = [
  ("/help", "查看可用命令"),
  ("/new", "开始新的会话"),
  ("/clear", "清空当前消息"),
  ("/status", "查看运行状态"),
  ("/model", "查看当前模型"),
  ("/about", "了解 MoonSage"),
]

///|
fn welcome_messages() -> Array[Message] {
  [
    {
      role: "assistant",
      text: "## 欢迎使用 MoonSage\n\n可以帮你搜索 Mooncakes、检查项目，或直接讨论代码。\n\n- 输入 `/` 查看命令\n- 支持中文与 Markdown\n- 会话会保存在本机浏览器中",
    },
    {
      role: "assistant",
      text: "当前界面通过同源服务连接 MoonSage Agent。模型与密钥配置保留在服务端，不会发送到浏览器。",
    },
  ]
}

///|
fn default_sessions() -> Array[Session] {
  [
    {
      id: "welcome",
      title: "欢迎使用 MoonSage",
      detail: "刚刚",
      messages: welcome_messages(),
    },
  ]
}

///|
fn initial_model() -> Model {
  let (sessions, active_session, next_id) = match load_persisted_state() {
    Some((sessions, active, next)) => (sessions, active, next)
    None => (default_sessions(), 0, 2)
  }
  let active = if active_session >= 0 && active_session < sessions.length() {
    active_session
  } else {
    0
  }
  {
    draft: "",
    sessions,
    active_session: active,
    request: Idle,
    command_open: false,
    sidebar_open: @dom.window().inner_width() > 720,
    workspace: initial_workspace(),
    next_id,
  }
}

///|
fn append_message(
  messages : Array[Message],
  message : Message,
) -> Array[Message] {
  let next = Array::copy(messages)
  next.push(message)
  next
}

///|
fn active_messages(model : Model) -> Array[Message] {
  model.sessions[model.active_session].messages
}

///|
fn set_active_messages(model : Model, messages : Array[Message]) -> Model {
  let sessions = Array::copy(model.sessions)
  let session = sessions[model.active_session]
  sessions[model.active_session] = { ..session, messages, }
  { ..model, sessions, }
}

///|
fn append_session_message(
  model : Model,
  session_id : String,
  message : Message,
) -> Model {
  let sessions = Array::copy(model.sessions)
  for index, session in sessions {
    if session.id == session_id {
      sessions[index] = {
        ..session,
        messages: append_message(session.messages, message),
      }
      break
    }
  }
  { ..model, sessions, }
}

///|
fn session_messages(model : Model, session_id : String) -> Array[Message] {
  for session in model.sessions {
    if session.id == session_id {
      return session.messages
    }
  }
  []
}

///|
fn append_exchange(model : Model, prompt : String, answer : String) -> Model {
  let messages = append_message(
    append_message(active_messages(model), { role: "user", text: prompt }),
    { role: "assistant", text: answer },
  )
  set_active_messages(model, messages)
}

///|
// Name a fresh session after its first user prompt instead of leaving
// every session titled 新会话.
fn with_title_for_first_prompt(model : Model, prompt : String) -> Model {
  let sessions = Array::copy(model.sessions)
  let session = sessions[model.active_session]
  if session.title == "新会话" && !prompt.trim().is_empty() {
    let title = if prompt.length() > 24 {
      prompt[:24].to_owned() + "…"
    } else {
      prompt
    }
    sessions[model.active_session] = { ..session, title, detail: "刚刚" }
    { ..model, sessions, }
  } else {
    model
  }
}

///|
fn command_answer(command : String) -> String? {
  match command {
    "/help" =>
      Some(
        "## 可用命令\n\n- `/new` 新会话\n- `/clear` 清空消息\n- `/status` 运行状态\n- `/model` 当前模型\n- `/about` 关于 MoonSage",
      )
    "/status" =>
      Some(
        "## 运行状态\n\n- 前端：Rabbita 0.14.2\n- 目标：JavaScript\n- 连接：MoonSage Agent API\n- 状态：就绪",
      )
    "/model" =>
      Some(
        "当前模型由服务端 `MOONSAGE_MODEL` 配置，API Key 不会暴露到浏览器。",
      )
    "/about" =>
      Some(
        "MoonSage 是面向 MoonBit 生态的 Agent 工作台，当前 GUI 使用 Rabbita 构建。",
      )
    _ => None
  }
}

///|
fn fresh_request(
  model : Model,
  session_id : String,
  prompt : String,
  status : String,
) -> (Model, Request) {
  let request_id = model.next_id
  let request : Request = {
    id: request_id,
    session_id,
    prompt,
    status,
    answer_buf: [],
    answer_shown: "",
    thinking_buf: [],
    thinking_shown: "",
    flush_pending: false,
    tools: [],
    warning: "",
    history_truncated: false,
  }
  ({ ..model, request: Sending(request), next_id: request_id + 1 }, request)
}

///|
fn retry_status(attempt : Int, reason : String) -> String {
  if reason == "" {
    "正在重试（第 \{attempt} 次）"
  } else {
    "正在重试（第 \{attempt} 次：\{reason}）"
  }
}

///|
fn join_chunks(chunks : Array[String]) -> String {
  let out = StringBuilder::new()
  for chunk in chunks {
    out.write_string(chunk)
  }
  out.to_string()
}

///|
// The partial answer is committed as an assistant message when the user
// stops a run, and the request returns to Idle.
fn finish_stopped(model : Model, request : Request) -> (Model, Cmd) {
  let answer = request.answer_shown + join_chunks(request.answer_buf)
  let next = if answer.trim() == "" {
    { ..model, request: Idle }
  } else {
    let appended = append_session_message(model, request.session_id, {
      role: "assistant",
      text: answer,
    })
    { ..appended, request: Idle }
  }
  (next, persist_model(next))
}

///|
fn update_conversation(
  model : Model,
  msg : Msg,
  emit : Emit[Msg],
) -> (Model, Cmd) {
  match msg {
    DraftChanged(value) =>
      (
        { ..model, draft: value, command_open: value.has_prefix("/") },
        @rabbita.none,
      )
    UsePrompt(value) =>
      ({ ..model, draft: value, command_open: false }, @rabbita.none)
    Submit => {
      let text = model.draft.trim().to_owned()
      if text == "" || model.request is Sending(_) {
        (model, @rabbita.none)
      } else if text == "/new" {
        update(model, NewSession, emit)
      } else if text == "/clear" {
        let next = set_active_messages(
          { ..model, draft: "", command_open: false },
          [],
        )
        (next, persist_model(next))
      } else {
        match command_answer(text) {
          Some(answer) => {
            let next = {
              ..append_exchange(model, text, answer),
              draft: "",
              command_open: false,
            }
            (next, persist_model(next))
          }
          None => {
            let session_id = model.sessions[model.active_session].id
            let with_message = set_active_messages(
              model,
              append_message(active_messages(model), { role: "user", text }),
            )
            let titled = with_title_for_first_prompt(with_message, text)
            let (next, request) = fresh_request(
              titled, session_id, text, "正在连接 Agent",
            )
            let payload = next.sessions[next.active_session].messages
            let ready = { ..next, draft: "", command_open: false }
            (
              ready,
              @cmd.batch([
                request_agent(emit, session_id, request.id, payload),
                persist_model(ready),
              ]),
            )
          }
        }
      }
    }
    CancelRequest =>
      match model.request {
        Sending(request) => {
          abort_agent_request()
          finish_stopped(model, request)
        }
        _ => (model, @rabbita.none)
      }
    AgentStatus(request_id, status) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          ({ ..model, request: Sending({ ..request, status, }) }, @rabbita.none)
        _ => (model, @rabbita.none)
      }
    AgentDelta(request_id, delta) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let buf = Array::copy(request.answer_buf)
          buf.push(delta)
          let command = if request.flush_pending {
            @rabbita.none
          } else {
            @cmd.delay(emit(AgentFlush(request_id)), 100)
          }
          (
            {
              ..model,
              request: Sending({
                ..request,
                answer_buf: buf,
                flush_pending: true,
              }),
            },
            command,
          )
        }
        _ => (model, @rabbita.none)
      }
    AgentThinking(request_id, text) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let buf = Array::copy(request.thinking_buf)
          buf.push(text)
          let command = if request.flush_pending {
            @rabbita.none
          } else {
            @cmd.delay(emit(AgentFlush(request_id)), 100)
          }
          (
            {
              ..model,
              request: Sending({
                ..request,
                thinking_buf: buf,
                flush_pending: true,
              }),
            },
            command,
          )
        }
        _ => (model, @rabbita.none)
      }
    AgentFlush(request_id) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let shown = request.answer_shown + join_chunks(request.answer_buf)
          let thinking_shown = request.thinking_shown +
            join_chunks(request.thinking_buf)
          (
            {
              ..model,
              request: Sending({
                ..request,
                answer_shown: shown,
                thinking_shown,
                answer_buf: [],
                thinking_buf: [],
                flush_pending: false,
              }),
            },
            after_render_scroll(),
          )
        }
        _ => (model, @rabbita.none)
      }
    AgentMeta(request_id, truncated) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          (
            {
              ..model,
              request: Sending({ ..request, history_truncated: truncated }),
            },
            @rabbita.none,
          )
        _ => (model, @rabbita.none)
      }
    AgentToolStarted(request_id, call_id, name, arguments, round) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let tools = Array::copy(request.tools)
          tools.push({
            id: call_id,
            name,
            arguments,
            status: "running",
            result: "",
            round,
          })
          (
            { ..model, request: Sending({ ..request, tools, }) },
            after_render_scroll(),
          )
        }
        _ => (model, @rabbita.none)
      }
    AgentToolFinished(request_id, call_id, status, result) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let tools = Array::copy(request.tools)
          for index, tool in tools {
            if tool.id == call_id && tool.status == "running" {
              tools[index] = { ..tool, status, result }
              break
            }
          }
          (
            { ..model, request: Sending({ ..request, tools, }) },
            after_render_scroll(),
          )
        }
        _ => (model, @rabbita.none)
      }
    AgentRetry(request_id, attempt, reason) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          (
            {
              ..model,
              request: Sending({
                ..request,
                status: retry_status(attempt, reason),
              }),
            },
            @rabbita.none,
          )
        _ => (model, @rabbita.none)
      }
    AgentWarning(request_id, message) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          (
            { ..model, request: Sending({ ..request, warning: message }) },
            @rabbita.none,
          )
        _ => (model, @rabbita.none)
      }
    AgentFinished(request_id) =>
      match model.request {
        Sending(request) if request.id == request_id => {
          let answer = request.answer_shown + join_chunks(request.answer_buf)
          if answer.trim() == "" {
            (
              {
                ..model,
                request: Failed(request, "Agent 没有返回内容。"),
              },
              @rabbita.none,
            )
          } else {
            let next = append_session_message(model, request.session_id, {
              role: "assistant",
              text: answer,
            })
            let finished = { ..next, request: Idle }
            (
              finished,
              @cmd.batch([persist_model(finished), after_render_scroll()]),
            )
          }
        }
        _ => (model, @rabbita.none)
      }
    AgentFailed(request_id, reason) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          ({ ..model, request: Failed(request, reason) }, @rabbita.none)
        _ => (model, @rabbita.none)
      }
    AgentStopped(request_id) =>
      match model.request {
        Sending(request) if request.id == request_id =>
          finish_stopped(model, request)
        _ => (model, @rabbita.none)
      }
    Retry =>
      match model.request {
        Failed(request, _) => {
          abort_agent_request()
          let session_id = request.session_id
          let prompt = request.prompt
          let (next, fresh) = fresh_request(
            model, session_id, prompt, "正在重新连接",
          )
          (
            next,
            @cmd.batch([
              request_agent(
                emit,
                session_id,
                fresh.id,
                session_messages(next, session_id),
              ),
              persist_model(next),
            ]),
          )
        }
        _ => (model, @rabbita.none)
      }
    RunCommand(command) => update({ ..model, draft: command }, Submit, emit)
    SelectSession(index) =>
      (
        { ..model, active_session: index, command_open: false },
        after_render_scroll(),
      )
    ToggleSidebar =>
      ({ ..model, sidebar_open: !model.sidebar_open }, @rabbita.none)
    NewSession => {
      let sessions = Array::copy(model.sessions)
      let session_id = "session-\{model.next_id}"
      sessions.push({
        id: session_id,
        title: "新会话",
        detail: "刚刚",
        messages: [
          {
            role: "assistant",
            text: "新的会话已准备好。你想从哪里开始？",
          },
        ],
      })
      let next = {
        draft: "",
        sessions,
        active_session: sessions.length() - 1,
        request: model.request,
        command_open: false,
        sidebar_open: @dom.window().inner_width() > 720,
        workspace: model.workspace,
        next_id: model.next_id + 1,
      }
      (next, @cmd.batch([persist_model(next), after_render_scroll()]))
    }
    _ => (model, @rabbita.none)
  }
}

///|
fn update(model : Model, msg : Msg, emit : Emit[Msg]) -> (Model, Cmd) {
  match workspace_update(model.workspace, msg, emit) {
    Some((workspace, command)) => ({ ..model, workspace, }, command)
    None => update_conversation(model, msg, emit)
  }
}

///|
fn message_view(message : Message) -> Html {
  let label = if message.role == "user" { "你" } else { "MoonSage" }
  let kind = if message.role == "user" { "message user" } else { "message" }
  if message.role == "user" {
    div(class=kind, [
      span(class="message-label", label),
      div(class="message-body", [p(class="message-text", message.text)]),
    ])
  } else {
    div(class=kind, [
      span(class="message-avatar", "M"),
      div(class="message-content", [
        span(class="message-label", label),
        markdown_view(message.text),
      ]),
    ])
  }
}

///|
fn clip_payload(text : String) -> String {
  if text.length() <= 2000 {
    text
  } else {
    text[:2000].to_owned() + "\n…（已截断）"
  }
}

///|
fn tool_card_view(tool : ToolCall) -> Html {
  let running = tool.status == "running"
  let status_label = if running {
    "运行中"
  } else if tool.status == "ok" || tool.status == "success" {
    "完成"
  } else {
    tool.status
  }
  details(class="tool-call", [
    summary([
      span(class=if running { "tool-dot running" } else { "tool-dot" }, ""),
      span(class="tool-name", tool.name),
      span(
        class="tool-round",
        if tool.round > 0 {
          "第 \{tool.round} 轮"
        } else {
          ""
        },
      ),
      span(class="tool-status", status_label),
    ]),
    if tool.arguments != "" {
      pre(class="tool-payload", clip_payload(tool.arguments))
    } else {
      div(class="prompt-placeholder", "")
    },
    if tool.result != "" {
      pre(class="tool-payload result", clip_payload(tool.result))
    } else {
      div(class="prompt-placeholder", "")
    },
  ])
}

///|
fn stop_button(emit : Emit[Msg]) -> Html {
  button(
    class="stop-button",
    type_="button",
    title="停止生成",
    attrs=@html.Attrs::build().aria_label("停止生成"),
    on_click=emit(CancelRequest),
    "停止",
  )
}

///|
fn prompt_suggestions(emit : Emit[Msg]) -> Html {
  let prompts = [
    ("探索 Mooncakes", "帮我查找适合当前项目的 MoonBit 包"),
    ("检查项目", "检查这个项目并给出下一步建议"),
    ("讨论代码", "帮我梳理当前代码的核心结构"),
  ]
  div(
    class="prompt-suggestions",
    [
      for pair in prompts => {
        let label = pair.0
        let prompt = pair.1
        button(
          class="prompt-chip",
          type_="button",
          on_click=emit(UsePrompt(prompt)),
          [span(label), span(class="prompt-arrow", "→")],
        )
      }
    ],
  )
}

///|
fn command_menu(draft : String, emit : Emit[Msg]) -> Html {
  let filtered = commands.filter(pair => pair.0.has_prefix(draft))
  let rows : Array[Html] = filtered.map(pair => {
    let command = pair.0
    let description = pair.1
    li([
      button(class="command-row", on_click=emit(RunCommand(command)), [
        span(class="command-name", command),
        span(class="command-description", description),
      ]),
    ])
  })
  div(class="command-menu", [
    div(class="command-heading", "命令 · \{filtered.length()}"),
    if rows.length() == 0 {
      p(class="command-empty", "没有匹配的命令")
    } else {
      ul(rows)
    },
  ])
}

///|
fn session_view(model : Model, emit : Emit[Msg]) -> Html {
  let rows : Array[Html] = [
    for index, session in model.sessions => {
      let class = if index == model.active_session {
        "session active"
      } else {
        "session"
      }
      button(class~, on_click=emit(SelectSession(index)), [
        span(class="session-title", session.title),
        span(class="session-detail", session.detail),
      ])
    }
  ]
  aside(class="sidebar", [
    div(class="sidebar-head", [
      div(class="brand", [span(class="brand-mark", "M"), span("MoonSage")]),
      button(
        class="sidebar-icon-button",
        title="折叠侧栏",
        attrs=@html.Attrs::build().aria_label("折叠侧栏"),
        on_click=emit(ToggleSidebar),
        "‹",
      ),
    ]),
    button(class="new-session", on_click=emit(NewSession), [
      span(class="new-session-icon", "+"),
      span("新对话"),
    ]),
    div(class="sidebar-label", "对话"),
    nav(class="session-list", rows),
    div(class="sidebar-footer", [
      span(class="footer-avatar", "M"),
      div(class="footer-copy", [span("Agent API"), span("同源连接")]),
      span(class="online-dot", ""),
    ]),
  ])
}

///|
fn request_state_view(
  request : RequestState,
  active_session_id : String,
  emit : Emit[Msg],
) -> Html {
  match request {
    Idle => div(class="request-placeholder", "")
    Sending(req) =>
      if req.session_id != active_session_id {
        div(class="request-placeholder", "")
      } else {
        div(class="streaming-response", [
          if req.history_truncated {
            div(
              class="stream-note",
              "更早的对话因长度限制未包含在本次请求中。",
            )
          } else {
            div(class="prompt-placeholder", "")
          },
          if req.warning != "" {
            div(class="stream-note warning", req.warning)
          } else {
            div(class="prompt-placeholder", "")
          },
          if req.tools.is_empty() {
            div(class="prompt-placeholder", "")
          } else {
            div(
              class="tool-calls",
              [
                for tool in req.tools => tool_card_view(tool)
              ],
            )
          },
          if req.thinking_shown != "" {
            details(class="thinking-panel", [
              summary([span(class="thinking-label", "思考过程")]),
              div(class="thinking-body", req.thinking_shown),
            ])
          } else {
            div(class="prompt-placeholder", "")
          },
          if req.answer_shown == "" {
            div(class="streaming-status", [
              span(class="typing-dots", [span(""), span(""), span("")]),
              span(class="streaming-status-text", req.status),
              stop_button(emit),
            ])
          } else {
            div([
              message_view({ role: "assistant", text: req.answer_shown }),
              div(class="streaming-status", [
                span(class="topbar-dot busy", ""),
                span(class="streaming-status-text", req.status),
                stop_button(emit),
              ]),
            ])
          },
        ])
      }
    Failed(_, reason) =>
      div(class="request-state failed", [
        div([span(class="request-title", "请求失败"), p(reason)]),
        button(class="retry-button", on_click=emit(Retry), "重试"),
      ])
  }
}

///|
fn request_label(request : RequestState) -> String {
  match request {
    Idle => "就绪"
    Sending(_) => "生成中"
    Failed(_, _) => "请求失败"
  }
}

///|
fn request_dot_class(request : RequestState) -> String {
  match request {
    Idle => "topbar-dot"
    Sending(_) => "topbar-dot busy"
    Failed(_, _) => "topbar-dot error"
  }
}

///|
fn app() -> Val[Html] {
  let (model, emit) = @rabbita.create_state(initial_model(), update~)
  model.view(model => {
    let active = model.sessions[model.active_session]
    let content : Array[Html] = active.messages.map(message_view)
    let shell_class = if model.sidebar_open {
      "shell sidebar-open"
    } else {
      "shell sidebar-closed"
    }
    let shell_class = if model.workspace.open {
      shell_class + " workspace-open"
    } else {
      shell_class
    }
    let sending = model.request is Sending(_)
    div(class=shell_class, [
      session_view(model, emit),
      if model.sidebar_open {
        button(
          class="sidebar-scrim",
          title="关闭侧栏",
          attrs=@html.Attrs::build().aria_label("关闭侧栏"),
          on_click=emit(ToggleSidebar),
          "",
        )
      } else {
        div(class="sidebar-placeholder", "")
      },
      main_(class="main-panel", [
        header(class="topbar", [
          button(
            class="icon-button",
            title="切换侧栏",
            attrs=@html.Attrs::build().aria_label("切换侧栏"),
            on_click=emit(ToggleSidebar),
            "=",
          ),
          div(class="conversation-heading", [
            h1(active.title),
            span(class="conversation-meta", "MoonSage · \{active.detail}"),
          ]),
          div(class="runtime-info", [
            span(class=request_dot_class(model.request), ""),
            span(request_label(model.request)),
          ]),
          button(
            class=if model.workspace.open {
              "workspace-toggle active"
            } else {
              "workspace-toggle"
            },
            type_="button",
            title="切换工作区",
            attrs=@html.Attrs::build().aria_label("切换工作区"),
            on_click=emit(ToggleWorkspace),
            "</>",
          ),
        ]),
        section(class="message-scroll", [
          div(class="message-column", [
            if content.length() == 0 {
              div(class="empty-state", [
                div(class="empty-mark", "M"),
                h1("开始新的对话"),
                p("描述任务，或输入 / 查看命令。"),
              ])
            } else {
              div(content)
            },
            if active.messages.length() == 2 && model.active_session == 0 {
              prompt_suggestions(emit)
            } else {
              div(class="prompt-placeholder", "")
            },
            request_state_view(model.request, active.id, emit),
          ]),
        ]),
        section(class="composer-area", [
          if model.command_open && !sending {
            command_menu(model.draft, emit)
          } else {
            div(class="menu-placeholder", "")
          },
          form(class="composer", on_submit=emit(Submit), [
            button(
              class="composer-tool",
              type_="button",
              title="添加上下文",
              attrs=@html.Attrs::build().aria_label("添加上下文"),
              on_click=emit(UsePrompt("请先了解当前项目上下文")),
              "+",
            ),
            textarea(
              class="composer-input",
              value=model.draft,
              rows=1,
              placeholder="输入消息，或输入 / 查看命令",
              autofocus=true,
              disabled=sending,
              attrs=@html.Attrs::build()
                .aria_label("消息")
                .on_keydown(event => {
                  if event.key() == "Enter" &&
                    !event.shift_key() &&
                    !event.is_composing() {
                    event.prevent_default()
                    emit(Submit)
                  } else {
                    @rabbita.none
                  }
                }),
              on_input=emit.map(value => DraftChanged(value)),
              "",
            ),
            button(
              class="send-button",
              type_="submit",
              title="发送消息",
              attrs=@html.Attrs::build().aria_label("发送消息"),
              disabled=sending || model.draft.trim().is_empty(),
              if sending {
                "···"
              } else {
                "↑"
              },
            ),
          ]),
          div(
            class="composer-hint",
            "MoonSage 可能会出错，请核对重要信息",
          ),
        ]),
      ]),
      if model.workspace.open {
        workspace_view(model.workspace, emit)
      } else {
        div(class="workspace-placeholder", "")
      },
    ])
  })
}

///|
fn main {
  @rabbita.new(app).mount("app")
}
