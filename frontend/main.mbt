///|
using @rabbita {type Cmd, type Emit, type Html, type Val}

///|
using @html {
  aside,
  button,
  div,
  form,
  h1,
  header,
  input,
  li,
  main_,
  nav,
  p,
  section,
  span,
  ul,
}

///|
struct Message {
  role : String
  text : String
} derive(Eq)

///|
struct Session {
  id : String
  title : String
  detail : String
  messages : Array[Message]
} derive(Eq)

///|
enum RequestState {
  Idle
  Sending(String, String)
  Failed(String, String, String)
} derive(Eq)

///|
struct Model {
  draft : String
  sessions : Array[Session]
  active_session : Int
  request : RequestState
  command_open : Bool
  sidebar_open : Bool
} derive(Eq)

///|
enum Msg {
  DraftChanged(String)
  UsePrompt(String)
  Submit
  AgentReplied(String, String)
  AgentFailed(String, String, String)
  Retry
  RunCommand(String)
  SelectSession(Int)
  ToggleSidebar
  NewSession
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
      text: "## 欢迎使用 MoonSage\n\n可以帮你搜索 Mooncakes、检查项目，或直接讨论代码。\n\n- 输入 `/` 查看命令\n- 支持中文与 Markdown\n- 会话内容会独立保存",
    },
    {
      role: "assistant",
      text: "当前界面通过同源服务连接 MoonSage Agent。模型与密钥配置保留在服务端，不会发送到浏览器。",
    },
  ]
}

///|
fn initial_model() -> Model {
  {
    draft: "",
    sessions: [
      {
        id: "welcome",
        title: "欢迎使用 MoonSage",
        detail: "刚刚",
        messages: welcome_messages(),
      },
      {
        id: "tui-refactor",
        title: "MoonBit TUI 重构",
        detail: "昨天",
        messages: [
          {
            role: "assistant",
            text: "## TUI 重构\n\n`chat` 与 `tui` 已拆分为独立入口。",
          },
        ],
      },
      {
        id: "http-research",
        title: "HTTP 客户端调研",
        detail: "周一",
        messages: [
          {
            role: "assistant",
            text: "Agent API 已接入同源服务端点，支持保留当前会话上下文。",
          },
        ],
      },
    ],
    active_session: 0,
    request: Idle,
    command_open: false,
    sidebar_open: @dom.window().inner_width() > 720,
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
fn update(model : Model, msg : Msg, emit : Emit[Msg]) -> (Model, Cmd) {
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
      if text == "" || model.request is Sending(_, _) {
        (model, @rabbita.none)
      } else if text == "/new" {
        update(model, NewSession, emit)
      } else if text == "/clear" {
        (
          set_active_messages({ ..model, draft: "", command_open: false }, []),
          @rabbita.none,
        )
      } else {
        match command_answer(text) {
          Some(answer) =>
            (
              {
                ..append_exchange(model, text, answer),
                draft: "",
                command_open: false,
              },
              @rabbita.none,
            )
          None => {
            let session_id = model.sessions[model.active_session].id
            let next = set_active_messages(
              model,
              append_message(active_messages(model), { role: "user", text }),
            )
            (
              {
                ..next,
                draft: "",
                command_open: false,
                request: Sending(session_id, text),
              },
              request_agent(
                emit,
                session_id,
                text,
                next.sessions[next.active_session].messages,
              ),
            )
          }
        }
      }
    }
    AgentReplied(session_id, answer) => {
      let next = append_session_message(model, session_id, {
        role: "assistant",
        text: answer,
      })
      ({ ..next, request: Idle }, @rabbita.none)
    }
    AgentFailed(session_id, prompt, reason) =>
      ({ ..model, request: Failed(session_id, prompt, reason) }, @rabbita.none)
    Retry =>
      match model.request {
        Failed(session_id, prompt, _) =>
          (
            { ..model, request: Sending(session_id, prompt) },
            request_agent(
              emit,
              session_id,
              prompt,
              session_messages(model, session_id),
            ),
          )
        _ => (model, @rabbita.none)
      }
    RunCommand(command) => update({ ..model, draft: command }, Submit, emit)
    SelectSession(index) =>
      ({ ..model, active_session: index, command_open: false }, @rabbita.none)
    ToggleSidebar =>
      ({ ..model, sidebar_open: !model.sidebar_open }, @rabbita.none)
    NewSession => {
      let sessions = Array::copy(model.sessions)
      sessions.push({
        id: "session-\{sessions.length()}",
        title: "新会话",
        detail: "刚刚",
        messages: [
          {
            role: "assistant",
            text: "新的会话已准备好。你想从哪里开始？",
          },
        ],
      })
      (
        {
          draft: "",
          sessions,
          active_session: sessions.length() - 1,
          request: model.request,
          command_open: false,
          sidebar_open: @dom.window().inner_width() > 720,
        },
        @rabbita.none,
      )
    }
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
        div(class="message-text markdown", markdown_view(message.text)),
      ]),
    ])
  }
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
fn request_state_view(request : RequestState, emit : Emit[Msg]) -> Html {
  match request {
    Idle => div(class="request-placeholder", "")
    Sending(_, _) =>
      div(class="request-state sending", [
        span(class="typing-dots", [span(""), span(""), span("")]),
        span("MoonSage 正在思考"),
      ])
    Failed(_, _, reason) =>
      div(class="request-state failed", [
        div([span(class="request-title", "请求失败"), p(reason)]),
        button(class="retry-button", on_click=emit(Retry), "重试"),
      ])
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
            "≡",
          ),
          div(class="conversation-heading", [
            h1(active.title),
            span(class="conversation-meta", "MoonSage · \{active.detail}"),
          ]),
          div(class="runtime-info", [
            span(class="topbar-dot", ""),
            span("就绪"),
          ]),
        ]),
        section(class="message-scroll", [
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
          request_state_view(model.request, emit),
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
            input(
              value=model.draft,
              placeholder="输入消息，或输入 / 查看命令",
              autofocus=true,
              attrs=@html.Attrs::build().aria_label("消息").disabled(sending),
              on_input=emit.map(value => DraftChanged(value)),
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
    ])
  })
}

///|
fn main {
  @rabbita.new(app).mount("app")
}
