///|
using @rabbita {type Html, type Val, type Emit}

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
  title : String
  detail : String
} derive(Eq)

///|
struct Model {
  draft : String
  messages : Array[Message]
  sessions : Array[Session]
  active_session : Int
  command_open : Bool
  sidebar_open : Bool
} derive(Eq)

///|
enum Msg {
  DraftChanged(String)
  Submit
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
]

///|
fn initial_model() -> Model {
  {
    draft: "",
    messages: [
      {
        role: "assistant",
        text: "你好，我是 MoonSage。可以帮你搜索 Mooncakes、检查项目，或直接讨论代码。",
      },
      {
        role: "assistant",
        text: "这是 Rabbita 前端演示。输入内容后按 Enter，或输入 / 打开命令菜单。",
      },
    ],
    sessions: [
      { title: "欢迎使用 MoonSage", detail: "刚刚" },
      { title: "MoonBit TUI 重构", detail: "昨天" },
      { title: "HTTP 客户端调研", detail: "周一" },
    ],
    active_session: 0,
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
fn update(model : Model, msg : Msg) -> Model {
  match msg {
    DraftChanged(value) =>
      { ..model, draft: value, command_open: value.has_prefix("/") }
    Submit => {
      let text = model.draft.trim().to_owned()
      if text == "" {
        model
      } else if text == "/new" {
        update(model, NewSession)
      } else if text == "/clear" {
        { ..model, draft: "", messages: [], command_open: false }
      } else if text == "/help" || text == "/status" {
        let answer = if text == "/help" {
          "可用命令：/help、/new、/clear、/status"
        } else {
          "状态正常 · Rabbita · 本地演示会话"
        }
        {
          ..model,
          draft: "",
          command_open: false,
          messages: append_message(
            append_message(model.messages, { role: "user", text }),
            { role: "assistant", text: answer },
          ),
        }
      } else {
        {
          ..model,
          draft: "",
          command_open: false,
          messages: append_message(
            append_message(model.messages, { role: "user", text }),
            {
              role: "assistant",
              text: "已收到。连接 Agent API 后，这里会显示真实的流式回答。",
            },
          ),
        }
      }
    }
    RunCommand(command) => update({ ..model, draft: command }, Submit)
    SelectSession(index) => { ..model, active_session: index }
    ToggleSidebar => { ..model, sidebar_open: !model.sidebar_open }
    NewSession =>
      {
        ..model,
        draft: "",
        messages: [{ role: "assistant", text: "新的会话已准备好。" }],
        command_open: false,
      }
  }
}

///|
fn message_view(message : Message) -> Html {
  let label = if message.role == "user" { "你" } else { "MoonSage" }
  let kind = if message.role == "user" { "message user" } else { "message" }
  div(class=kind, [
    span(class="message-label", label),
    p(class="message-text", message.text),
  ])
}

///|
fn command_menu(emit : Emit[Msg]) -> Html {
  let rows : Array[Html] = commands.map(pair => {
    let command = pair.0
    let description = pair.1
    li([
      button(class="command-row", on_click=emit(RunCommand(command)), [
        span(class="command-name", command),
        span(class="command-description", description),
      ]),
    ])
  })
  div(class="command-menu", [div(class="command-heading", "命令"), ul(rows)])
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
    div(class="brand", "MOONSAGE"),
    button(class="new-session", on_click=emit(NewSession), "+  新会话"),
    div(class="sidebar-label", "最近会话"),
    nav(class="session-list", rows),
    div(class="sidebar-footer", [
      span(class="online-dot", "●"),
      span("本地演示模式"),
    ]),
  ])
}

///|
fn app() -> Val[Html] {
  let (model, emit) = @rabbita.create_pure_state(initial_model(), update~)
  model.view(model => {
    let active = model.sessions[model.active_session]
    let content : Array[Html] = model.messages.map(message_view)
    let shell_class = if model.sidebar_open {
      "shell sidebar-open"
    } else {
      "shell sidebar-closed"
    }
    div(class=shell_class, [
      session_view(model, emit),
      main_(class="main-panel", [
        header(class="topbar", [
          button(class="icon-button", on_click=emit(ToggleSidebar), "☰"),
          div(class="conversation-heading", [
            h1(active.title),
            span(class="conversation-meta", "在线 · \{active.detail}"),
          ]),
          span(class="model-badge", "Rabbita UI"),
        ]),
        section(class="message-scroll", content),
        section(class="composer-area", [
          if model.command_open {
            command_menu(emit)
          } else {
            div(class="menu-placeholder", "")
          },
          form(class="composer", on_submit=emit(Submit), [
            input(
              value=model.draft,
              placeholder="输入消息，或输入 / 查看命令",
              autofocus=true,
              attrs=@html.Attrs::build().on_keydown(event => {
                if event.key() == "Enter" {
                  emit(Submit)
                } else {
                  @rabbita.none
                }
              }),
              on_input=emit.map(value => DraftChanged(value)),
            ),
            button(class="send-button", type_="submit", "发送"),
          ]),
        ]),
      ]),
    ])
  })
}

///|
fn main {
  @rabbita.new(app).mount("app")
}
