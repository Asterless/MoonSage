///|
// 从工具参数 JSON 中读取字符串字段。
pub fn json_string_arg(document : Json, key : String) -> String {
  match document {
    Object(fields) =>
      match fields.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
// 将项目相对路径解析为绝对路径，拒绝穿越、绝对路径与反斜杠。
pub fn safe_path(root : String, rel : String) -> String raise {
  guard rel != "" &&
    !rel.contains("..") &&
    !rel.contains("\\") &&
    !rel.contains(":") &&
    !rel.has_prefix("/") &&
    !rel.has_prefix("\\") else {
    fail("invalid path: \{rel}")
  }
  root + "/" + rel
}

///|
fn relative_to_root(root : String, path : String) -> String {
  if path.has_prefix(root + "/") {
    path[root.length() + 1:].to_owned()
  } else {
    path
  }
}

///|
fn truncate_output(s : String, max : Int) -> String {
  if s.length() > max {
    s[:max].to_owned() + "\n... (truncated)"
  } else {
    s
  }
}

///|
fn parse_int_or(s : String, default : Int) -> Int {
  @string.parse_int(s) catch {
    _ => default
  }
}

///|
async fn collect_project_files(
  dir : String,
  root : String,
  out : Array[String],
) -> Unit {
  let entries = @fs.readdir(dir, sort=true)
  for entry in entries {
    if entry == "_build" ||
      entry == ".git" ||
      entry == ".mooncakes" ||
      entry == "target" {
      continue
    }
    let path = dir + "/" + entry
    if @fs.kind(path) is @fs.FileKind::Directory {
      collect_project_files(path, root, out)
    } else {
      out.push(relative_to_root(root, path))
    }
  }
}

///|
async fn list_project_files_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let sub = json_string_arg(document, "path")
  let dir = if sub == "" { root } else { safe_path(root, sub) }
  let files : Array[String] = []
  collect_project_files(dir, root, files)
  files.to_json().stringify()
}

///|
async fn read_file_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let rel = json_string_arg(document, "path")
  let path = safe_path(root, rel)
  let start = json_string_arg(document, "start")
  let end = json_string_arg(document, "end")
  let data = @fs.read_file(path)
  let lines = data.text().split("\n").map(fn(s) { s.to_owned() }).to_array()
  let first = parse_int_or(start, 1)
  let last = parse_int_or(end, lines.length())
  let first = if first < 1 { 1 } else { first }
  let last = if last > lines.length() { lines.length() } else { last }
  let out = StringBuilder::new()
  for i = first; i <= last; i = i + 1 {
    out.write_string(i.to_string())
    out.write_string(": ")
    out.write_string(lines[i - 1])
    out.write_string("\n")
  }
  truncate_output(out.to_string(), 16000)
}

///|
async fn run_moon_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let args_text = json_string_arg(document, "args")
  let args = args_text
    .split(" ")
    .filter(fn(s) { s != "" })
    .map(fn(s) { s.to_owned() })
    .to_array()
  guard args.length() > 0 else { fail("args must not be empty") }
  let (exit, out, err) = @process.collect_output(
    "moon",
    args,
    cwd=root,
    no_console_window=true,
  )
  Json::object({
    "exit_code": Json::number(exit.to_double()),
    "stdout": Json::string(truncate_output(out.text(), 6000)),
    "stderr": Json::string(truncate_output(err.text(), 2000)),
  }).stringify()
}

///|
pub async fn git_diff(root : String, path : String?) -> String {
  let args = if path is Some(p) { ["diff", "--", p] } else { ["diff"] }
  let (exit, out, _) = @process.collect_output(
    "git",
    args,
    cwd=root,
    no_console_window=true,
  )
  if exit != 0 {
    "(git diff failed)"
  } else {
    out.text() catch {
      _ => ""
    }
  }
}

///|
async fn git_diff_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments) catch { _ => Json::object({}) }
  let path = json_string_arg(document, "path")
  let limited = if path != "" {
    ignore(safe_path(root, path))
    Some(path)
  } else {
    None
  }
  git_diff(root, limited)
}

///|
// 只读本地工具集：作用于 root 目录（当前工作目录或审计克隆目录）。
pub fn local_tools(root : String) -> Array[@tools.Tool] {
  [
    {
      schema: {
        name: "list_project_files",
        description: "List files in the project (relative paths), excluding build caches and .git.",
        parameters: @tools.object_schema(
          {
            "path": @tools.string_field(
              "Optional subdirectory to list instead of the project root",
            ),
          },
          [],
        ),
      },
      execute: async fn(arguments) {
        list_project_files_tool(root, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "read_file",
        description: "Read a project file with line numbers. Optionally restrict to a line range.",
        parameters: @tools.object_schema(
          {
            "path": @tools.string_field("Relative file path"),
            "start": @tools.string_field("Optional 1-based first line to show"),
            "end": @tools.string_field("Optional 1-based last line to show"),
          },
          ["path"],
        ),
      },
      execute: async fn(arguments) {
        read_file_tool(root, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "run_moon",
        description: "Run a moon command inside the project (e.g. 'build' or 'test'). Returns exit code, stdout and stderr.",
        parameters: @tools.object_schema(
          {
            "args": @tools.string_field(
              "Space-separated moon arguments, for example 'build' or 'test'",
            ),
          },
          ["args"],
        ),
      },
      execute: async fn(arguments) {
        run_moon_tool(root, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "git_diff",
        description: "Show the current uncommitted changes as a unified diff.",
        parameters: @tools.object_schema(
          {
            "path": @tools.string_field(
              "Optional relative path to limit the diff",
            ),
          },
          [],
        ),
      },
      execute: async fn(arguments) { git_diff_tool(root, arguments) },
    },
  ]
}
