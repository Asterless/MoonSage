///|
test "moonsage logo is a stable five-line slanted wordmark" {
  inspect(
    moonsage_logo,
    content=(
      #|    __  ______  ____  _   _______ ___   ____________
      #|   /  |/  / __ \/ __ \/ | / / ___//   | / ____/ ____/
      #|  / /|_/ / / / / / / /  |/ /\__ \/ /| |/ / __/ __/
      #| / /  / / /_/ / /_/ / /|  /___/ / ___ / /_/ / /___
      #|/_/  /_/\____/\____/_/ |_//____/_/  |_\____/_____/
    ),
  )
}

///|
test "slash input opens, filters, and selects the command menu" {
  let composer = ChatComposer::new(100)
  assert_true(composer.handle_input("/") is Changed)
  assert_eq(composer.command_suggestions().length(), 11)
  let menu = composer.frame_lines().join("\n")
  assert_true(menu.contains("/help"))
  assert_true(menu.contains("Show available commands"))
  assert_true(menu.contains("3 more commands"))
  assert_true(composer.handle_input("\u001b[B") is Changed)
  assert_eq(composer.selected_command, 1)
  assert_true(composer.handle_input("\r") is Submit)
  assert_eq(composer.input.get_text(), "/status")
}

///|
test "runtime status and startup header show active configuration" {
  let session = @runtime.Session::from_json(Json::array([]))
  let composer = ChatComposer::new(100)
  composer.set_runtime_status("deepseek-chat", @ai.OpenAi, "chat-123", session)
  let frame = composer.frame_lines().join("\n")
  assert_true(frame.contains("deepseek-chat"))
  assert_true(frame.contains("openai"))
  assert_true(frame.contains("context 0%"))
  assert_true(frame.contains("chat-123"))
  let header = startup_info(
    100,
    "deepseek-chat",
    @ai.OpenAi,
    "chat-123",
    "D:/work/moonsage",
    session,
  )
  assert_true(header.contains("Model      deepseek-chat (openai)"))
  assert_true(header.contains("Session    chat-123"))
  assert_true(header.contains("Workspace  D:/work/moonsage"))
  assert_true(header.contains("Context  [----------------]"))
  assert_true(header.contains("Permissions  confirm file edits"))
}

///|
test "composer keeps unicode input and cursor aligned across redraws" {
  let composer = ChatComposer::new(80)
  assert_true(composer.handle_input("中文") is Changed)
  assert_eq(composer.input.get_text(), "中文")
  assert_eq(composer.cursor_column(), 7)
  let first = composer.draw_frame()
  assert_true(first.contains("中文"))
  assert_true(composer.handle_input("\u007f") is Changed)
  assert_eq(composer.input.get_text(), "中")
  let second = composer.draw_frame()
  assert_true(second.contains("\u001b[2K"))
  assert_eq(composer.cursor_column(), 5)
}

///|
test "composer clips menu rows to terminal display width" {
  let composer = ChatComposer::new(24)
  ignore(composer.handle_input("/"))
  for line in composer.frame_lines() {
    let plain = line
      .replace(old="\u001b[36;1m", new="")
      .replace(old="\u001b[90m", new="")
      .replace(old="\u001b[0m", new="")
    assert_true(@core.string_display_width(plain) < 24)
  }
}
