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
  if s.length() <= max || max <= 0 {
    return if max <= 0 { "" } else { s }
  }
  let marker = "\n... (truncated)\n"
  let budget = max - marker.length()
  if budget <= 0 {
    return marker
  }
  let lines = s.split("\n").to_array()
  let head_budget = budget / 2
  let tail_budget = budget - head_budget
  let head : Array[String] = []
  let mut head_len = 0
  for line in lines {
    let extra = line.length() + (if head.length() > 0 { 1 } else { 0 })
    if head_len + extra > head_budget {
      break
    }
    head.push(line.to_owned())
    head_len += extra
  }
  let tail : Array[String] = []
  let mut tail_len = 0
  let mut index = lines.length() - 1
  while index >= 0 {
    let line = lines[index]
    let extra = line.length() + (if tail.length() > 0 { 1 } else { 0 })
    if tail_len + extra > tail_budget {
      break
    }
    tail.push(line.to_owned())
    tail_len += extra
    index -= 1
  }
  if head.length() == 0 && lines.length() > 0 {
    let first = lines[0]
    head.push(first[:head_budget].to_owned())
  }
  if tail.length() == 0 && lines.length() > 0 {
    let last = lines[lines.length() - 1]
    let start = if last.length() > tail_budget {
      last.length() - tail_budget
    } else {
      0
    }
    tail.push(last[start:].to_owned())
  }
  let out = StringBuilder::new()
  for i = 0; i < head.length(); i = i + 1 {
    if i > 0 {
      out.write_char('\n')
    }
    out.write_string(head[i])
  }
  out.write_string(marker)
  for i = tail.length() - 1; i >= 0; i = i - 1 {
    if i < tail.length() - 1 {
      out.write_char('\n')
    }
    out.write_string(tail[i])
  }
  out.to_string()
}

///|
// 列文件上限与 grep 结果上限,防止大仓库把上下文打爆。
let list_files_max_entries = 2000

///|
let collect_files_hard_cap = 10000

///|
let grep_max_matches_default = 200

///|
let grep_max_line_chars = 200

///|
// Keep local agent file access aligned with the dev server workspace policy.
// Directory names are matched case-insensitively because workspace paths may
// come from a case-insensitive filesystem.
fn is_ignored_project_entry(name : String) -> Bool {
  let normalized = name.to_lower()
  normalized == ".git" ||
  normalized == ".mooncakes" ||
  normalized == ".moonsage" ||
  normalized == ".cache" ||
  normalized == "_build" ||
  normalized == "_build.bak" ||
  normalized == "node_modules" ||
  normalized == "target" ||
  normalized.has_prefix("_audit_ws_")
}

///|
fn is_ignored_project_path(path : String) -> Bool {
  let segments = path.replace(old="\\", new="/").split("/")
  for segment_view in segments {
    let segment = segment_view.to_owned()
    if is_ignored_project_entry(segment) || segment.to_lower() == ".env" {
      return true
    }
  }
  false
}

///|
async fn collect_project_files(
  dir : String,
  root : String,
  out : Array[String],
  max : Int,
) -> Unit {
  let entries = @fs.readdir(dir, sort=true)
  for entry in entries {
    if out.length() >= max {
      return
    }
    if is_ignored_project_entry(entry) || entry.to_lower() == ".env" {
      continue
    }
    let path = dir + "/" + entry
    let kind = @fs.kind(path, follow_symlink=false) catch { _ => continue }
    match kind {
      Directory => collect_project_files(path, root, out, max)
      Regular => out.push(relative_to_root(root, path))
      // Never follow repository-controlled symlinks or special files while
      // collecting source for an agent.
      _ => ()
    }
  }
}

///|
async fn checked_project_path(
  root : String,
  rel : String,
  require_directory? : Bool = false,
) -> String {
  guard !is_ignored_project_path(rel) else { fail("path is ignored: \{rel}") }
  let target = @util.safe_path(root, rel)
  let segments = rel
    .replace_all(old="\\", new="/")
    .split("/")
    .filter(fn(segment) { segment != "" && segment != "." })
    .map(fn(segment) { segment.to_owned() })
    .to_array()
  let mut current = root.trim_end(chars="\\/").to_owned()
  for index, segment in segments {
    current = current + "/" + segment
    let kind = @fs.kind(current, follow_symlink=false) catch {
      _ => fail("path does not exist: \{rel}")
    }
    guard !(kind is SymLink) else {
      fail("symbolic links are not accessible: \{rel}")
    }
    if index + 1 < segments.length() {
      guard kind is Directory else {
        fail("path contains a non-directory component: \{rel}")
      }
    } else if require_directory {
      guard kind is Directory else { fail("path is not a directory: \{rel}") }
    } else {
      guard kind is Regular else { fail("path is not a regular file: \{rel}") }
    }
  }
  target
}

///|
// 简单的通配符匹配:支持 * 与 ?。用于 list_project_files 的 pattern 过滤。
fn wildcard_match(pattern : String, text : String) -> Bool {
  match_here(pattern, 0, text, 0)
}

///|
fn match_here(pattern : String, pi : Int, text : String, ti : Int) -> Bool {
  if pi == pattern.length() {
    return ti == text.length()
  }
  if pattern[pi] == '*' {
    // 跳过连续 *。
    let mut p = pi
    while p < pattern.length() && pattern[p] == '*' {
      p = p + 1
    }
    for t = ti; t <= text.length(); t = t + 1 {
      if match_here(pattern, p, text, t) {
        return true
      }
    }
    return false
  }
  if ti < text.length() && (pattern[pi] == '?' || pattern[pi] == text[ti]) {
    return match_here(pattern, pi + 1, text, ti + 1)
  }
  false
}

///|
async fn list_project_files_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let sub = @util.json_string_arg(document, "path")
  let pattern = @util.json_string_arg(document, "pattern")
  guard sub == "" || !is_ignored_project_path(sub) else {
    fail("path is ignored: \{sub}")
  }
  let dir = if sub == "" {
    root
  } else {
    checked_project_path(root, sub, require_directory=true)
  }
  let files : Array[String] = []
  collect_project_files(dir, root, files, collect_files_hard_cap)
  let filtered = if pattern != "" {
    files.filter(fn(f) { wildcard_match(pattern, f) })
  } else {
    files
  }
  let mut truncated = false
  let shown = filtered
  if shown.length() > list_files_max_entries {
    shown.truncate(list_files_max_entries)
    truncated = true
  }
  Json::object({
    "files": Json::array(shown.map(Json::string)),
    "truncated": Json::boolean(truncated),
  }).stringify()
}

///|
async fn grep_files_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let pattern = @util.json_string_arg(document, "pattern")
  let sub = @util.json_string_arg(document, "path")
  let max_matches = @util.parse_int_or(
    @util.json_string_arg(document, "max_matches"),
    grep_max_matches_default,
  )
  guard pattern != "" else { fail("pattern is required") }
  guard sub == "" || !is_ignored_project_path(sub) else {
    fail("path is ignored: \{sub}")
  }
  let dir = if sub == "" {
    root
  } else {
    checked_project_path(root, sub, require_directory=true)
  }
  let needle = pattern.to_lower()
  let files : Array[String] = []
  collect_project_files(dir, root, files, collect_files_hard_cap)
  let matches : Array[String] = []
  for file in files {
    if matches.length() >= max_matches {
      break
    }
    let read_result = Some(
      @fs.read_file(checked_project_path(root, file)).text(),
    ) catch {
      _ => None
    }
    match read_result {
      None => ()
      Some(content) => {
        let lines = content.split("\n").map(fn(s) { s.to_owned() }).to_array()
        for i = 0; i < lines.length(); i = i + 1 {
          if matches.length() >= max_matches {
            break
          }
          if lines[i].to_lower().contains(needle) {
            let line = lines[i]
            let shown = if line.length() > grep_max_line_chars {
              line[:grep_max_line_chars].to_owned() + "…"
            } else {
              line
            }
            matches.push("\{file}:\{i + 1}: \{shown}")
          }
        }
      }
    }
  }
  Json::object({
    "matches": Json::array(matches.map(Json::string)),
    "truncated": Json::boolean(matches.length() >= max_matches),
  }).stringify()
}

///|
async fn read_file_tool(root : String, arguments : String) -> String {
  let document = @json.parse(arguments)
  let rel = @util.json_string_arg(document, "path")
  let path = checked_project_path(root, rel)
  let start = @util.json_string_arg(document, "start")
  let end = @util.json_string_arg(document, "end")
  let data = @fs.read_file(path)
  let lines = data.text().split("\n").map(fn(s) { s.to_owned() }).to_array()
  let first = @util.parse_int_or(start, 1)
  let last = @util.parse_int_or(end, lines.length())
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
  let args_text = @util.json_string_arg(document, "args")
  let args = args_text
    .split(" ")
    .filter(fn(s) { s != "" })
    .map(fn(s) { s.to_owned() })
    .to_array()
  guard args.length() > 0 else { fail("args must not be empty") }
  let timeout_ms = @util.parse_int_or(
    @util.json_string_arg(document, "timeout_ms"),
    run_moon_default_timeout_ms,
  )
  let timeout_ms = if timeout_ms < 1000 { 1000 } else { timeout_ms }
  run_moon_with_timeout(root, args, timeout_ms)
}

///|
fn verification_args(command : String) -> Array[String] raise {
  guard command == "check" || command == "build" || command == "test" else {
    fail("verification command must be check, build, or test")
  }
  [command, "--target", "native"]
}

///|
fn verification_environment() -> Map[String, String] {
  let environment : Map[String, String] = Map([])
  for
    name in [
      "PATH", "HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "TEMP", "TMP", "MOON_HOME",
      "MOONBIT_HOME", "SystemRoot", "ComSpec", "PATHEXT",
    ] {
    match @sys.get_env_var(name) {
      Some(value) if value != "" => environment[name] = value
      _ => ()
    }
  }
  environment
}

///|
#cfg(platform="windows")
fn local_git_null_device() -> String {
  "NUL"
}

///|
#cfg(not(platform="windows"))
fn local_git_null_device() -> String {
  "/dev/null"
}

///|
fn repository_read_environment() -> Map[String, String] {
  let environment = verification_environment()
  environment["GIT_CONFIG_GLOBAL"] = local_git_null_device()
  environment["GIT_LFS_SKIP_SMUDGE"] = "1"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  environment["GCM_INTERACTIVE"] = "Never"
  environment
}

///|
// Batch audits run untrusted repositories. Keep model and GitHub credentials
// in the orchestrator process and expose only the toolchain environment here.
pub async fn run_moon_verification(
  root : String,
  command : String,
  timeout_ms? : Int = run_moon_default_timeout_ms,
) -> String {
  let args = verification_args(command)
  let timeout_ms = if timeout_ms < 1000 { 1000 } else { timeout_ms }
  let payload = @async.with_timeout_opt(timeout_ms, async fn() {
    let (exit, out, err) = @process.collect_output(
      "moon",
      args,
      cwd=root,
      extra_env=verification_environment(),
      inherit_env=false,
      no_console_window=true,
    )
    Json::object({
      "exit_code": Json::number(exit.to_double()),
      "stdout": Json::string(truncate_output(out.text(), 6000)),
      "stderr": Json::string(truncate_output(err.text(), 2000)),
    }).stringify()
  })
  match payload {
    Some(result) => result
    None => command_timeout_json(timeout_ms)
  }
}

///|
pub fn verification_tools(ws : @editing.Workspace) -> Array[@tools.Tool] {
  [
    {
      schema: {
        name: "run_moon",
        description: "Run one required MoonBit verification command in the workspace. command must be check, build, or test; target is always native and credentials are not inherited.",
        parameters: @tools.object_schema(
          {
            "command": @tools.string_field("check, build, or test"),
            "timeout_ms": @tools.string_field(
              "Optional timeout in milliseconds",
            ),
          },
          ["command"],
        ),
      },
      execute: async fn(arguments) {
        try {
          let document = @json.parse(arguments)
          let command = @util.json_string_arg(document, "command")
          let timeout_ms = @util.parse_int_or(
            @util.json_string_arg(document, "timeout_ms"),
            run_moon_default_timeout_ms,
          )
          run_moon_verification(ws.get_root(), command, timeout_ms~)
        } catch {
          error => @tools.error_json(error.to_string())
        }
      },
    },
  ]
}

///|
// Default cap for a single `run_moon` call: 5 minutes.
// A hung moon process must not block the whole agent session forever.
let run_moon_default_timeout_ms : Int = 300000

///|
// Run `moon` with a timeout. When the deadline hits, the process is
// cancelled (terminated) and a structured JSON result is returned so the
// agent can recover instead of hanging indefinitely.
async fn run_moon_with_timeout(
  root : String,
  args : Array[String],
  timeout_ms : Int,
) -> String {
  run_command_with_timeout("moon", root, args, timeout_ms)
}

///|
// Run any command with a timeout. On timeout the child process is cancelled
// (terminated) and a structured JSON result is returned instead of hanging.
async fn run_command_with_timeout(
  cmd : String,
  root : String,
  args : Array[String],
  timeout_ms : Int,
) -> String {
  let payload = @async.with_timeout_opt(timeout_ms, async fn() {
    let (exit, out, err) = @process.collect_output(
      cmd,
      args,
      cwd=root,
      no_console_window=true,
    )
    Json::object({
      "exit_code": Json::number(exit.to_double()),
      "stdout": Json::string(truncate_output(out.text(), 6000)),
      "stderr": Json::string(truncate_output(err.text(), 2000)),
    }).stringify()
  })
  match payload {
    Some(result) => result
    None => command_timeout_json(timeout_ms)
  }
}

///|
fn command_timeout_json(timeout_ms : Int) -> String {
  Json::object({
    "exit_code": Json::number(-1.0),
    "stdout": Json::string(""),
    "stderr": Json::string(
      "command timed out after \{timeout_ms} ms and was terminated",
    ),
  }).stringify()
}

///|
pub async fn git_diff(root : String, path : String?) -> String {
  let args = [
    "-c",
    "core.hooksPath=\{local_git_null_device()}",
    "-c",
    "credential.helper=",
    "-c",
    "submodule.recurse=false",
    "diff",
    "--no-ext-diff",
    "--no-textconv",
  ]
  match path {
    Some(value) => {
      args.push("--")
      args.push(value)
    }
    None => ()
  }
  let (exit, out, _) = @process.collect_output(
    "git",
    args,
    cwd=root,
    extra_env=repository_read_environment(),
    inherit_env=false,
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
  let path = @util.json_string_arg(document, "path")
  let limited = if path != "" {
    guard !is_ignored_project_path(path) else {
      fail("path is ignored: \{path}")
    }
    ignore(@util.safe_path(root, path))
    Some(path)
  } else {
    None
  }
  git_diff(root, limited)
}

///|
// 只读本地工具集：作用于 Workspace 当前根目录。
pub fn local_tools(ws : @editing.Workspace) -> Array[@tools.Tool] {
  [
    {
      schema: {
        name: "list_project_files",
        description: "List files in the project (relative paths), excluding build caches and .git. Optionally filter by a wildcard pattern (* and ?). Returns {files, truncated}.",
        parameters: @tools.object_schema(
          {
            "path": @tools.string_field(
              "Optional subdirectory to list instead of the project root",
            ),
            "pattern": @tools.string_field(
              "Optional wildcard filter on relative paths, e.g. '*.mbt' or 'src/*.mbt'",
            ),
          },
          [],
        ),
      },
      execute: async fn(arguments) {
        list_project_files_tool(ws.get_root(), arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "grep_files",
        description: "Search file contents for a case-insensitive substring across the project; returns matching lines as path:line: text, capped at max_matches.",
        parameters: @tools.object_schema(
          {
            "pattern": @tools.string_field(
              "Substring to search for (case-insensitive)",
            ),
            "path": @tools.string_field(
              "Optional subdirectory to search instead of the project root",
            ),
            "max_matches": @tools.string_field(
              "Optional maximum number of matches (default 200)",
            ),
          },
          ["pattern"],
        ),
      },
      execute: async fn(arguments) {
        grep_files_tool(ws.get_root(), arguments) catch {
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
        read_file_tool(ws.get_root(), arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "run_moon",
        description: "Run a moon command inside the project (e.g. 'build' or 'test'). Returns exit code, stdout and stderr. The process is capped at 5 minutes by default.",
        parameters: @tools.object_schema(
          {
            "args": @tools.string_field(
              "Space-separated moon arguments, for example 'build' or 'test'",
            ),
            "timeout_ms": @tools.string_field(
              "Optional timeout in milliseconds for the moon process (default \{run_moon_default_timeout_ms})",
            ),
          },
          ["args"],
        ),
      },
      execute: async fn(arguments) {
        run_moon_tool(ws.get_root(), arguments) catch {
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
      execute: async fn(arguments) { git_diff_tool(ws.get_root(), arguments) },
    },
  ]
}
