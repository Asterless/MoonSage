///|
using @rabbita {type Cmd, type Emit, type Html, type Val}

///|
using @html {
  a,
  article,
  aside,
  button,
  details,
  div,
  form,
  h1,
  h2,
  h3,
  header,
  input,
  label,
  li,
  main_,
  nav,
  p,
  pre,
  section,
  small,
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
  theme : String
  compact : Bool
  workspace_overlay : Bool
  workspace : WorkspaceModel
  batch : BatchModel
  next_id : Int
  pending_new_session : Bool
  session_filter : String
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
  ToggleTheme
  ViewportChanged(Int)
  NewSession
  SessionFilterChanged(String)
  ToggleWorkspace
  WorkspacePick
  WorkspacePicked(String)
  WorkspaceSelect(String)
  WorkspaceCreateWorktree
  WorkspacePin
  WorkspaceDelete
  WorkspaceHandoff(String)
  WorkspaceDirtySave
  WorkspaceDirtyDiscard
  WorkspaceDirtyCancel
  WorkspaceTabSelected(String)
  WorkspaceRegistryReceived(String)
  WorkspaceRegistryReload
  WorkspaceTreeReceived(String, String)
  WorkspaceFilterChanged(String)
  WorkspaceToggleGroup(String)
  WorkspaceSelectFile(String)
  WorkspaceFileReceived(String, String, String)
  WorkspaceContentChanged(String)
  WorkspaceSaveFile
  WorkspaceFileSaved(String, String, String)
  WorkspaceStatusReceived(String, String)
  WorkspaceDiffScopeChanged(String)
  WorkspaceDiffReceived(String, String, String, String)
  WorkspaceRefresh
  WorkspaceStage(String)
  WorkspaceUnstage(String)
  WorkspaceGitActionReceived(String, String, String)
  WorkspaceCommitMessageChanged(String)
  WorkspaceCommit
  WorkspaceCommitReceived(String, String)
  WorkspaceFailed(String)
  ToggleBatch
  BatchConfigChanged(String, String)
  BatchStart
  BatchRefresh
  BatchSelect(String)
  BatchSelectItem(String)
  BatchAction(String, String, String)
  BatchResponse(String, String)
  BatchFailed(String)
  BatchPoll
  BatchStreamChanged
  BatchActivity(String)
  BatchActivityTab(Bool)
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
      text: "## 欢迎使用 MoonSage\n\n以工作区任务为中心：先读取本地项目，再根据你的目标检查、修改和验证文件。\n\n- 对话只用于描述任务目标\n- 输入 `/` 查看命令\n- 支持中文与 Markdown",
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
fn resolved_active_session_index(
  sessions : Array[Session],
  stored_index : Int,
  bound_session_id : String,
) -> Int {
  if bound_session_id != "" {
    for index, session in sessions {
      if session.id == bound_session_id {
        return index
      }
    }
  }
  if stored_index >= 0 && stored_index < sessions.length() {
    stored_index
  } else {
    0
  }
}

///|
fn initial_model() -> Model {
  let (sessions, active_session, next_id) = match load_persisted_state() {
    Some((sessions, active, next)) => (sessions, active, next)
    None => (default_sessions(), 0, 2)
  }
  let (stored_workspace_id, stored_session_id) = load_workspace_binding()
  let active = resolved_active_session_index(
    sessions, active_session, stored_session_id,
  )
  let width = @dom.window().inner_width()
  let compact = is_compact_width(width)
  let workspace_overlay = is_workspace_overlay_width(width)
  let theme = load_theme()
  apply_document_theme(theme)
  {
    draft: "",
    sessions,
    active_session: active,
    request: Idle,
    command_open: false,
    sidebar_open: !compact,
    theme,
    compact,
    workspace_overlay,
    workspace: {
      ..initial_workspace(),
      id: stored_workspace_id,
      session_id: sessions[active].id,
    },
    batch: initial_batch(),
    next_id,
    pending_new_session: false,
    session_filter: "",
  }
}

///|
fn is_compact_width(width : Int) -> Bool {
  width <= 760
}

///|
fn is_workspace_overlay_width(width : Int) -> Bool {
  width <= 1040
}

///|
fn with_viewport_width(model : Model, width : Int) -> Model {
  let compact = is_compact_width(width)
  let workspace_overlay = is_workspace_overlay_width(width)
  if compact == model.compact && workspace_overlay == model.workspace_overlay {
    model
  } else {
    {
      ..model,
      compact,
      workspace_overlay,
      sidebar_open: if compact == model.compact {
        model.sidebar_open
      } else {
        !compact
      },
    }
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
                request_agent(
                  emit,
                  session_id,
                  request.id,
                  payload,
                  next.workspace.id,
                  next.workspace.mode,
                ),
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
                next.workspace.id,
                next.workspace.mode,
              ),
              persist_model(next),
            ]),
          )
        }
        _ => (model, @rabbita.none)
      }
    RunCommand(command) => update({ ..model, draft: command }, Submit, emit)
    SelectSession(index) => {
      let selected_session_id = model.sessions[index].id
      let next = {
        ..model,
        active_session: index,
        workspace: { ..model.workspace, session_id: selected_session_id },
        command_open: false,
        sidebar_open: if model.compact {
          false
        } else {
          model.sidebar_open
        },
      }
      let command = if model.compact {
        @cmd.batch([
          persist_model(next),
          after_render_scroll(),
          after_render_focus(".composer-input"),
          persist_workspace_binding(next.workspace.id, selected_session_id),
        ])
      } else {
        @cmd.batch([
          persist_model(next),
          after_render_scroll(),
          persist_workspace_binding(next.workspace.id, selected_session_id),
        ])
      }
      (next, command)
    }
    ToggleSidebar => {
      let sidebar_open = !model.sidebar_open
      (
        { ..model, sidebar_open, },
        after_render_focus(
          if sidebar_open {
            ".sidebar .sidebar-icon-button"
          } else {
            ".topbar > .icon-button"
          },
        ),
      )
    }
    SessionFilterChanged(value) =>
      ({ ..model, session_filter: value }, @rabbita.none)
    ToggleTheme => {
      let theme = opposite_theme(model.theme)
      ({ ..model, theme, }, persist_theme(theme))
    }
    ViewportChanged(width) => {
      let next = with_viewport_width(model, width)
      let command = if model.sidebar_open && !next.sidebar_open {
        after_render_focus(
          if model.workspace.open && next.workspace_overlay {
            ".workspace-panel .workspace-icon-button"
          } else {
            ".topbar > .icon-button"
          },
        )
      } else if model.workspace.open &&
        !model.workspace_overlay &&
        next.workspace_overlay {
        after_render_focus(".workspace-panel .workspace-icon-button")
      } else {
        @rabbita.none
      }
      (next, command)
    }
    NewSession =>
      if model.pending_new_session {
        (model, @rabbita.none)
      } else {
        // Workspace-first flow: a new conversation starts by choosing or
        // creating a workspace, then the session is created once the user
        // picks one (WorkspacePicked / WorkspaceSelect).
        let next = {
          ..model,
          pending_new_session: true,
          draft: "",
          command_open: false,
        }
        if model.workspace.open {
          (next, @rabbita.none)
        } else {
          update(next, ToggleWorkspace, emit)
        }
      }
    _ => (model, @rabbita.none)
  }
}

///|
fn create_new_session(model : Model) -> (Model, Cmd) {
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
    ..model,
    draft: "",
    sessions,
    active_session: sessions.length() - 1,
    command_open: false,
    sidebar_open: !model.compact,
    next_id: model.next_id + 1,
    workspace: { ..model.workspace, session_id, },
    pending_new_session: false,
    session_filter: "",
  }
  (
    next,
    @cmd.batch([
      persist_model(next),
      persist_workspace_binding(next.workspace.id, session_id),
      after_render_scroll(),
      if model.compact {
        after_render_focus(".composer-input")
      } else {
        @rabbita.none
      },
    ]),
  )
}

///|
fn workspace_choose_completed(msg : Msg) -> Bool {
  match msg {
    WorkspacePicked(_) => true
    WorkspaceSelect(_) => true
    _ => false
  }
}

///|
fn update(model : Model, msg : Msg, emit : Emit[Msg]) -> (Model, Cmd) {
  match batch_update(model.batch, msg, emit) {
    Some((batch, command)) => ({ ..model, batch, }, command)
    None =>
      match workspace_update(model.workspace, msg, emit) {
        Some((workspace, command)) => {
          let next = { ..model, workspace, }
          if model.pending_new_session {
            if workspace_choose_completed(msg) && workspace.id != "" {
              // The user just picked a workspace; create the conversation
              // bound to it and keep the workspace loading command.
              let (created, session_command) = create_new_session(next)
              (created, @cmd.batch([session_command, command]))
            } else if msg is ToggleWorkspace && !workspace.open {
              // The panel was closed without choosing a workspace; cancel the
              // pending new conversation.
              ({ ..next, pending_new_session: false }, command)
            } else {
              (next, command)
            }
          } else {
            (next, command)
          }
        }
        None => update_conversation(model, msg, emit)
      }
  }
}

///|
fn icon(name : String) -> Html {
  span(
    class="icon icon-" + name,
    attrs=@html.Attrs::build().aria_hidden("true"),
    "",
  )
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
      span(class="message-avatar", [icon("sparkles")]),
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
      icon("chevron-right"),
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
    [icon("square"), span("停止")],
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
          [span(label), span(class="prompt-arrow", [icon("arrow-right")])],
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
      button(
        class="command-row",
        type_="button",
        attrs=@html.Attrs::build().role("menuitem"),
        on_click=emit(RunCommand(command)),
        [
          span(class="command-name", command),
          span(class="command-description", description),
        ],
      ),
    ])
  })
  div(
    class="command-menu",
    attrs=@html.Attrs::build().role("menu").aria_label("命令菜单"),
    [
      div(class="command-heading", "命令 · \{filtered.length()}"),
      if rows.length() == 0 {
        p(class="command-empty", "没有匹配的命令")
      } else {
        ul(rows)
      },
    ],
  )
}

///|
///|
fn group_sessions(
  sessions : Array[Session],
  filter : String,
) -> Array[(String, Array[(Int, Session)])] {
  // Apply filter first
  let filtered = if filter.trim() == "" {
    sessions
  } else {
    let lower = filter.trim().to_lower()
    sessions.filter(fn(s) {
      s.title.to_lower().contains(lower) || s.detail.to_lower().contains(lower)
    })
  }
  if filtered.is_empty() {
    return []
  }
  // Group by position: newest sessions at the end of the array
  let len = filtered.length()
  let groups : Array[(String, Array[(Int, Session)])] = []
  let today_start = if len >= 1 { len - 1 } else { 0 }
  let yesterday_start = if len >= 3 { len - 2 } else { 0 }
  // Build indexed items
  let items : Array[(Int, Session)] = []
  for i, session in filtered {
    items.push((i, session))
  }
  // Split into groups
  if today_start < len {
    let today_items : Array[(Int, Session)] = []
    for i = today_start; i < len; i = i + 1 {
      today_items.push(items[i])
    }
    groups.push(("今天", today_items))
  }
  if yesterday_start > 0 && yesterday_start < today_start {
    let yesterday_items : Array[(Int, Session)] = []
    for i = yesterday_start; i < today_start; i = i + 1 {
      yesterday_items.push(items[i])
    }
    groups.push(("昨天", yesterday_items))
  }
  if 0 < yesterday_start {
    let earlier_items : Array[(Int, Session)] = []
    for i = 0; i < yesterday_start; i = i + 1 {
      earlier_items.push(items[i])
    }
    groups.push(("更早", earlier_items))
  }
  groups
}
fn session_view(model : Model, emit : Emit[Msg]) -> Html {
  let workspace_modal = model.workspace.open && model.workspace_overlay
  let drawer_modal = model.sidebar_open && model.compact
  let sidebar_hidden = !model.sidebar_open || workspace_modal
  let base_sidebar_attrs = @html.Attrs::build()
    .aria_label("会话侧栏")
    .aria_hidden(if sidebar_hidden { "true" } else { "false" })
    .inert(sidebar_hidden)
  let sidebar_attrs = if drawer_modal {
    base_sidebar_attrs
    .role("dialog")
    .aria_modal("true")
    .on_keydown(event => {
      if event.key() == "Escape" {
        event.prevent_default()
        emit(ToggleSidebar)
      } else {
        @rabbita.none
      }
    })
  } else {
    base_sidebar_attrs
  }

  let groups = group_sessions(model.sessions, model.session_filter)
  let filter_empty = model.session_filter != "" && groups.is_empty()
  let session_rows : Array[Html] = []
  for group in groups {
    let label = group.0
    let items = group.1
    session_rows.push(div(class="sidebar-group-label", label))
    for item in items {
      let index = item.0
      let session = item.1
      let active = index == model.active_session
      let class = if active { "session active" } else { "session" }
      session_rows.push(
        button(
          class~,
          type_="button",
          attrs=@html.Attrs::build().aria_current(
            if active { "page" } else { "false" },
          ),
          on_click=emit(SelectSession(index)),
          [
            span(class="session-title", session.title),
            span(class="session-detail", session.detail),
          ],
        ),
      )
    }
  }

  let ws_label = if model.workspace.name != "" {
    model.workspace.name
  } else if model.workspace.root != "" {
    model.workspace.root
  } else {
    ""
  }
  aside(class="sidebar", attrs=sidebar_attrs, [
    div(class="sidebar-head", [
      div(class="brand", [
        span(class="brand-wordmark", "MoonSage"),
        span(class="brand-caption", "MOONBIT AGENT"),
      ]),
      button(
        class="sidebar-icon-button",
        type_="button",
        title="折叠侧栏",
        attrs=@html.Attrs::build().aria_label("折叠侧栏"),
        on_click=emit(ToggleSidebar),
        icon("panel-left-close"),
      ),
    ]),
    div(class="sidebar-search-wrap", [
      icon("search"),
      input(
        class="sidebar-search",
        value=model.session_filter,
        placeholder="搜索会话...",
        attrs=@html.Attrs::build().aria_label("搜索会话"),
        on_input=emit.map(value => SessionFilterChanged(value)),
      ),
    ]),
    button(class="new-session", type_="button", on_click=emit(NewSession), [
      icon("square-plus"),
      span("新对话"),
    ]),
    button(
      class="batch-entry",
      type_="button",
      attrs=@html.Attrs::build().aria_label("进入自动审计模式"),
      on_click=emit(ToggleBatch),
      [
        icon("sparkles"),
        span("自动审计"),
        span(class="batch-entry-kicker", "批量审计"),
      ],
    ),
    if filter_empty {
      div(class="session-list", [
        div(class="sidebar-group-label", "无匹配会话"),
      ])
    } else {
      nav(
        class="session-list",
        attrs=@html.Attrs::build().aria_label("会话列表"),
        session_rows,
      )
    },
    div(class="sidebar-footer", [
      div(class="connection-status", [
        span(class="online-dot", ""),
        div(class="footer-copy", [span("Agent API"), span("同源连接")]),
      ]),
      button(
        class=if ws_label == "" { "workspace-indicator empty" } else { "workspace-indicator" },
        type_="button",
        title=if ws_label != "" { ws_label } else { "选择工作区" },
        attrs=@html.Attrs::build().aria_label(
          if ws_label != "" { ws_label } else { "选择工作区" },
        ),
        on_click=emit(ToggleWorkspace),
        [
          icon("folder"),
          span(class="workspace-indicator-label",
            if ws_label != "" { ws_label } else { "未选择工作区" },
          ),
        ],
      ),
      div(class="sidebar-footer-theme", [
        button(
          class="theme-toggle",
          type_="button",
          title=if model.theme == "dark" {
            "切换浅色主题"
          } else {
            "切换暗色主题"
          },
          attrs=@html.Attrs::build()
            .aria_label(
              if model.theme == "dark" {
                "切换浅色主题"
              } else {
                "切换暗色主题"
              },
            )
            .aria_pressed(if model.theme == "dark" { "true" } else { "false" }),
          on_click=emit(ToggleTheme),
          if model.theme == "dark" {
            icon("sun")
          } else {
            icon("moon")
          },
        ),
      ]),
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
              summary([
                icon("chevron-right"),
                span(class="thinking-label", "思考过程"),
              ]),
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
        icon("circle-alert"),
        div(class="request-copy", [
          span(class="request-title", "请求失败"),
          p(reason),
        ]),
        button(class="retry-button", on_click=emit(Retry), [
          icon("rotate-ccw"),
          span("重试"),
        ]),
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
  let (model, emit) = @rabbita.create_state_with_init(
    init=fn(emit) { (initial_model(), load_workspace_registry(emit)) },
    update~,
    subscriptions=(_, emit) => {
      @sub.on_resize(viewport => emit(ViewportChanged(viewport.width)))
    },
  )
  model.view(model => {
    if model.batch.open {
      return batch_view(model.batch, model.theme, emit)
    }
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
    let workspace_modal = model.workspace.open && model.workspace_overlay
    let sidebar_modal = model.sidebar_open && model.compact
    let main_hidden = workspace_modal || sidebar_modal
    div(
      class=shell_class,
      attrs=@html.Attrs::build().data_set("theme", model.theme),
      [
        session_view(model, emit),
        if model.sidebar_open {
          button(
            class="sidebar-scrim",
            title="关闭侧栏",
            attrs=@html.Attrs::build()
              .aria_label("关闭侧栏")
              .aria_hidden(if workspace_modal { "true" } else { "false" })
              .inert(workspace_modal),
            on_click=emit(ToggleSidebar),
            "",
          )
        } else {
          div(class="sidebar-placeholder", "")
        },
        main_(
          class="main-panel",
          attrs=@html.Attrs::build()
            .aria_hidden(if main_hidden { "true" } else { "false" })
            .inert(main_hidden),
          [
            header(class="topbar", [
              button(
                class="icon-button",
                type_="button",
                title="切换侧栏",
                attrs=@html.Attrs::build()
                  .aria_label("切换侧栏")
                  .aria_pressed(
                    if model.sidebar_open {
                      "true"
                    } else {
                      "false"
                    },
                  ),
                on_click=emit(ToggleSidebar),
                icon("menu"),
              ),
              div(class="conversation-heading", [
                h1(active.title),
                span(
                  class="conversation-meta",
                  if model.workspace.name == "" {
                    "MoonSage · \{active.detail}"
                  } else {
                    "工作区 · \{model.workspace.name} · \{active.detail}"
                  },
                ),
              ]),
              div(
                class="runtime-info",
                attrs=@html.Attrs::build().role("status").aria_live("polite"),
                [
                  span(class=request_dot_class(model.request), ""),
                  span(request_label(model.request)),
                ],
              ),
              button(
                class="batch-mode-toggle",
                type_="button",
                title="自动审计",
                attrs=@html.Attrs::build().aria_label(
                  "进入自动审计模式",
                ),
                on_click=emit(ToggleBatch),
                [icon("sparkles"), span("自动审计")],
              ),
              button(
                class="icon-button topbar-theme-toggle",
                type_="button",
                title=if model.theme == "dark" {
                  "切换浅色主题"
                } else {
                  "切换暗色主题"
                },
                attrs=@html.Attrs::build()
                  .aria_label(
                    if model.theme == "dark" {
                      "切换浅色主题"
                    } else {
                      "切换暗色主题"
                    },
                  )
                  .aria_pressed(
                    if model.theme == "dark" {
                      "true"
                    } else {
                      "false"
                    },
                  ),
                on_click=emit(ToggleTheme),
                if model.theme == "dark" {
                  icon("sun")
                } else {
                  icon("moon")
                },
              ),
              button(
                class=if model.workspace.open {
                  "workspace-toggle active"
                } else {
                  "workspace-toggle"
                },
                type_="button",
                title="切换工作区",
                attrs=@html.Attrs::build()
                  .aria_label("切换工作区")
                  .aria_pressed(
                    if model.workspace.open {
                      "true"
                    } else {
                      "false"
                    },
                  ),
                on_click=emit(ToggleWorkspace),
                icon("panel-right"),
              ),
            ]),
            section(
              class="message-scroll",
              attrs=@html.Attrs::build().aria_label("对话内容"),
              [
                div(class="message-column", [
                  if content.length() == 0 {
                    div(class="empty-state", [
                      div(class="empty-mark", [icon("file-code-2")]),
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
              ],
            ),
            section(class="composer-area", [
              if model.command_open && !sending {
                command_menu(model.draft, emit)
              } else {
                div(class="menu-placeholder", "")
              },
              form(
                class="composer",
                attrs=@html.Attrs::build().aria_label("发送消息"),
                on_submit=emit(Submit),
                [
                  button(
                    class="composer-tool",
                    type_="button",
                    title="添加上下文",
                    attrs=@html.Attrs::build().aria_label("添加上下文"),
                    on_click=emit(
                      UsePrompt("请先了解当前项目上下文"),
                    ),
                    icon("paperclip"),
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
                      icon("loader-circle")
                    } else {
                      icon("arrow-up")
                    },
                  ),
                ],
              ),
              div(
                class="composer-hint",
                "MoonSage 可能会出错，请核对重要信息",
              ),
            ]),
          ],
        ),
        if model.workspace.open {
          workspace_view(
            model.workspace,
            workspace_modal,
            model.pending_new_session,
            emit,
          )
        } else {
          div(class="workspace-placeholder", "")
        },
      ],
    )
  })
}

///|
fn main {
  @rabbita.new(app).mount("app")
}
