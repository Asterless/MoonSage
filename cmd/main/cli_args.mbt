///|
#cfg(platform="windows")
extern "C" fn windows_command_line() -> String = "moonsage_get_command_line_utf16"

///|
fn command_line_space(char : Char) -> Bool {
  char == ' ' || char == '\t'
}

///|
fn write_backslashes(builder : StringBuilder, count : Int) -> Unit {
  for index = 0; index < count; index = index + 1 {
    builder.write_char('\\')
  }
}

///|
fn parse_windows_command_line(command_line : String) -> Array[String] {
  let args : Array[String] = []
  let length = command_line.length()
  let mut index = 0
  while index < length {
    while index < length &&
          command_line_space(command_line.get_char(index).unwrap()) {
      index += 1
    }
    if index >= length {
      break
    }
    let argument = StringBuilder::new()
    let mut quoted = false
    while index < length {
      let char = command_line.get_char(index).unwrap()
      if char == '\\' {
        let mut slash_count = 0
        while index < length && command_line.get_char(index).unwrap() == '\\' {
          slash_count += 1
          index += 1
        }
        if index < length && command_line.get_char(index).unwrap() == '"' {
          write_backslashes(argument, slash_count / 2)
          if slash_count % 2 == 0 {
            quoted = !quoted
          } else {
            argument.write_char('"')
          }
          index += 1
        } else {
          write_backslashes(argument, slash_count)
        }
      } else if char == '"' {
        quoted = !quoted
        index += 1
      } else if command_line_space(char) && !quoted {
        break
      } else {
        argument.write_char(char)
        index += char.utf16_len()
      }
    }
    args.push(argument.to_string())
  }
  args
}

///|
#cfg(platform="windows")
fn cli_args() -> Array[String] {
  parse_windows_command_line(windows_command_line())
}

///|
#cfg(not(platform="windows"))
fn cli_args() -> Array[String] {
  @sys.get_cli_args()
}

///|
test "parse unicode Windows command line" {
  let args = parse_windows_command_line(
    "moonsage.exe ask \"检查 async 包的 API 并给出使用建议\"",
  )
  assert_eq(args, [
    "moonsage.exe", "ask", "检查 async 包的 API 并给出使用建议",
  ])
}

///|
test "parse Windows quoted paths and escaped quotes" {
  let args = parse_windows_command_line(
    "moonsage.exe search \"http client\" \"say \\\"hello\\\"\"",
  )
  assert_eq(args, ["moonsage.exe", "search", "http client", "say \"hello\""])
}
