///|
// 修复模式下的写入确认方式。
priv enum ConfirmMode {
  // 每次写文件前在 stdin 询问
  ConfirmPrompt
  // 直接应用修改，结束时展示累计 diff
  ConfirmDiff
  // 不确认直接应用
  ConfirmYes
}

///|
// 审计上下文：项目目录、是否修复模式、确认方式。
priv struct AuditContext {
  project_dir : String
  fix : Bool
  confirm : ConfirmMode
}

///|
async fn write_file_tool(ctx : AuditContext, arguments : String) -> String {
  guard ctx.fix else {
    fail("write_file is disabled in read-only audit mode (use --fix)")
  }
  let document = @json.parse(arguments)
  let rel = @local.json_string_arg(document, "path")
  let content = @local.json_string_arg(document, "content")
  guard rel != "" else { fail("path is required") }
  let path = @local.safe_path(ctx.project_dir, rel)
  match ctx.confirm {
    ConfirmPrompt => {
      @stdio.stdout.write("[fix] overwrite \{rel}? [y/N] ")
      let answer = @stdio.stdin.read_until("\n") catch { _ => None }
      let ok = match answer {
        Some(s) => s.trim().to_lower() == "y" || s.trim().to_lower() == "yes"
        None => false
      }
      guard ok else { return "change declined by user" }
    }
    _ => ()
  }
  @fs.write_file(path, content, create_mode=@fs.CreateMode::CreateOrTruncate)
  "wrote \{rel}"
}

///|
fn basename(path : String) -> String {
  let parts = path.split("/").to_array()
  parts[parts.length() - 1].to_owned()
}

///|
// 修改后需要跑语法门校验的源码文件。
fn is_syncheck_source(rel : String) -> Bool {
  let base = basename(rel)
  base.has_suffix(".mbt") ||
  base.has_suffix(".mbt.md") ||
  base == "moon.mod" ||
  base == "moon.pkg"
}

///|
// 对修改后的单文件内容做语法校验：写入临时文件后运行 `moonc syncheck`。
async fn syncheck_content(content : String, rel : String) -> String {
  let tmp = @fs.tmpdir(prefix="moonsage-syncheck-")
  try {
    let file = tmp + "/" + basename(rel)
    let _ = @fs.write_file(
      file,
      content,
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let (exit, _, err) = @process.collect_output(
      "moonc",
      ["syncheck", file],
      no_console_window=true,
    )
    guard exit == 0 else {
      fail(
        "multi_edit: \{rel} 修改后无法通过语法检查:\n\{err.text()}",
      )
    }
  } catch {
    e => {
      @fs.rmdir(tmp, recursive=true) catch {
        _ => ()
      }
      raise e
    }
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
  content
}

///|
async fn multi_edit_tool(ctx : AuditContext, arguments : String) -> String {
  guard ctx.fix else {
    fail("multi_edit is disabled in read-only audit mode (use --fix)")
  }
  let document = @json.parse(arguments)
  guard document is Object(fields) else {
    fail("multi_edit arguments must be a JSON object")
  }
  guard fields.get("edits") is Some(Array(items)) else {
    fail("multi_edit requires an edits array")
  }
  let edits : Array[EditSpec] = []
  for item in items {
    guard item is Object(_) else { fail("each edit must be an object") }
    let file = @local.json_string_arg(item, "file")
    let old_string = @local.json_string_arg(item, "old_string")
    let new_string = @local.json_string_arg(item, "new_string")
    let start_line = parse_int_or(@local.json_string_arg(item, "start_line"), 1)
    let end_line = parse_int_or(@local.json_string_arg(item, "end_line"), 0)
    guard file != "" else { fail("each edit requires a file") }
    edits.push({ file, old_string, new_string, start_line, end_line })
  }
  guard edits.length() > 0 else { fail("edits must not be empty") }
  let original : Map[String, String] = Map([])
  for edit in edits {
    if original.get(edit.file) is None {
      let path = @local.safe_path(ctx.project_dir, edit.file)
      original[edit.file] = @fs.read_file(path).text()
    }
  }
  let results : Map[String, String] = Map([])
  for file, content in original {
    let file_edits : Array[EditSpec] = []
    for edit in edits {
      if edit.file == file {
        file_edits.push(edit)
      }
    }
    results[file] = apply_edits_to_file(content, file_edits)
  }
  // 语法门：全部通过才落盘（原子）。
  for file, new_content in results {
    if is_syncheck_source(file) {
      ignore(syncheck_content(new_content, file))
    }
  }
  let mut changed = 0
  for file, new_content in results {
    if original[file] != new_content {
      @fs.write_file(
        @local.safe_path(ctx.project_dir, file),
        new_content,
        create_mode=@fs.CreateMode::CreateOrTruncate,
      )
      changed += 1
    }
  }
  "applied \{edits.length()} edit(s) to \{changed} file(s)"
}

///|
async fn remove_tool(ctx : AuditContext, arguments : String) -> String {
  guard ctx.fix else {
    fail("remove is disabled in read-only audit mode (use --fix)")
  }
  let document = @json.parse(arguments)
  let rel = @local.json_string_arg(document, "path")
  guard rel != "" else { fail("path is required") }
  let path = @local.safe_path(ctx.project_dir, rel)
  guard @fs.kind(path) is @fs.FileKind::Regular else {
    fail("remove only supports regular files: \{rel}")
  }
  @fs.remove(path)
  "removed \{rel}"
}

///|
// 组装审计工具集：只读工具来自共享 local 包，write_file 仅在修复模式加入。
fn audit_tools(ctx : AuditContext) -> Array[@tools.Tool] {
  let base = @local.local_tools(ctx.project_dir)
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
      {
        schema: {
          name: "multi_edit",
          description: "Apply exact line-anchored replacements across one or more files in one validated batch (only available in fix mode). Each edit is {file, old_string, new_string, start_line, end_line}: old_string must match exactly once within the given 1-based line range; use an empty old_string to insert new_string at the start of start_line. The whole batch is atomic and must pass moonc syncheck before anything is written.",
          parameters: @tools.object_schema(
            {
              "edits": @tools.array_field(
                "Array of {file, old_string, new_string, start_line, end_line}",
              ),
            },
            ["edits"],
          ),
        },
        execute: async fn(arguments) {
          multi_edit_tool(ctx, arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        },
      },
      {
        schema: {
          name: "remove",
          description: "Delete a regular file from the project (only available in fix mode).",
          parameters: @tools.object_schema(
            { "path": @tools.string_field("Relative file path to delete") },
            ["path"],
          ),
        },
        execute: async fn(arguments) {
          remove_tool(ctx, arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        },
      },
    ]
  } else {
    base
  }
}
