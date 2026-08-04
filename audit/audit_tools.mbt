///|
// ???????
priv enum ConfirmMode {
  // ?????????????? stdin?
  ConfirmPrompt
  // ????????????? diff ?????
  ConfirmDiff
  // ????????
  ConfirmYes
}

///|
// ???????????????? + ??/?????
priv struct AuditContext {
  project_dir : String
  fix : Bool
  confirm : ConfirmMode
}

///|
fn audit_tool_arg(document : Json, key : String) -> String {
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
// ?????????????????????
fn safe_project_path(ctx : AuditContext, rel : String) -> String raise {
  guard rel != "" &&
    !rel.contains("..") &&
    !rel.contains("\\") &&
    !rel.has_prefix("/") &&
    !rel.has_prefix("\\") else {
    fail("invalid path: \{rel}")
  }
  ctx.project_dir + "/" + rel
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
fn truncate_output(s : String, max : Int) -> String {
  if s.length() > max {
    s[:max].to_owned() + "\n... (truncated)"
  } else {
    s
  }
}

///|
async fn list_project_files_tool(
  ctx : AuditContext,
  arguments : String,
) -> String {
  let document = @json.parse(arguments)
  let sub = audit_tool_arg(document, "path")
  let root = if sub == "" {
    ctx.project_dir
  } else {
    safe_project_path(ctx, sub)
  }
  let files : Array[String] = []
  collect_project_files(root, ctx.project_dir, files)
  files.to_json().stringify()
}

///|
async fn read_file_tool(ctx : AuditContext, arguments : String) -> String {
  let document = @json.parse(arguments)
  let rel = audit_tool_arg(document, "path")
  let path = safe_project_path(ctx, rel)
  let start = audit_tool_arg(document, "start")
  let end = audit_tool_arg(document, "end")
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
async fn run_moon_tool(ctx : AuditContext, arguments : String) -> String {
  let document = @json.parse(arguments)
  let args_text = audit_tool_arg(document, "args")
  let args = args_text
    .split(" ")
    .filter(fn(s) { s != "" })
    .map(fn(s) { s.to_owned() })
    .to_array()
  guard args.length() > 0 else { fail("args must not be empty") }
  let (exit, out, err) = @process.collect_output(
    "moon",
    args,
    cwd=ctx.project_dir,
    no_console_window=true,
  )
  Json::object({
    "exit_code": Json::number(exit.to_double()),
    "stdout": Json::string(truncate_output(out.text(), 6000)),
    "stderr": Json::string(truncate_output(err.text(), 2000)),
  }).stringify()
}

///|
async fn git_diff_tool(ctx : AuditContext, arguments : String) -> String {
  let document = @json.parse(arguments) catch { _ => Json::object({}) }
  let path = audit_tool_arg(document, "path")
  let limited = if path != "" { Some(path) } else { None }
  git_diff(ctx.project_dir, limited)
}

///|
async fn write_file_tool(ctx : AuditContext, arguments : String) -> String {
  guard ctx.fix else {
    fail("write_file is disabled in read-only audit mode (use --fix)")
  }
  let document = @json.parse(arguments)
  let rel = audit_tool_arg(document, "path")
  let content = audit_tool_arg(document, "content")
  guard rel != "" && content != "" else {
    fail("path and content are required")
  }
  let path = safe_project_path(ctx, rel)
  match ctx.confirm {
    ConfirmPrompt => {
      @stdio.stdout.write("[fix] overwrite \{rel}? [y/N] ")
      let answer = @stdio.stdin.read_until("\n")
      let ok = match answer {
        Some(s) => s.trim().to_lower() == "y" || s.trim().to_lower() == "yes"
        None => false
      }
      guard ok else { return "change declined by user" }
    }
    _ => ()
  }
  @fs.write_file(path, content)
  "wrote \{rel}"
}

///|
// ??????schema + execute?execute ?????????
fn audit_tools(ctx : AuditContext) -> Array[@tools.Tool] {
  let base : Array[@tools.Tool] = [
    {
      schema: {
        name: "list_project_files",
        description: "List files in the audited project (relative paths), excluding build caches and .git.",
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
        list_project_files_tool(ctx, arguments) catch {
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
        read_file_tool(ctx, arguments) catch {
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
        run_moon_tool(ctx, arguments) catch {
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
      execute: async fn(arguments) { git_diff_tool(ctx, arguments) },
    },
  ]
  if ctx.fix {
    base +
    [
      {
        schema: {
          name: "write_file",
          description: "Overwrite a project file with the given full content (only available in fix mode).",
          parameters: @tools.object_schema(
            {
              "path": @tools.string_field("Relative file path"),
              "content": @tools.string_field("Complete new file content"),
            },
            ["path", "content"],
          ),
        },
        execute: async fn(arguments) {
          write_file_tool(ctx, arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        },
      },
    ]
  } else {
    base
  }
}
