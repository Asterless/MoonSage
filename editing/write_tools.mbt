///|
// 写操作前的确认方式。
pub(all) enum WriteConfirm {
  // 每次写入前在 stdin 询问 y/N
  Prompt
  // 直接应用，不询问
  Auto
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
// 确认一次写入；Prompt 模式在 stdin 询问，拒绝返回 false。
async fn confirm_write(
  confirm : WriteConfirm,
  verb : String,
  target : String,
) -> Bool {
  if confirm is Auto {
    return true
  }
  @stdio.stdout.write("? 确认\{verb}\{target}？[y/N] ")
  let answer = @stdio.stdin.read_until("\n") catch { _ => None }
  match answer {
    Some(s) => s.trim().to_lower() == "y" || s.trim().to_lower() == "yes"
    None => false
  }
}

///|
async fn write_file_tool(
  root : String,
  confirm : WriteConfirm,
  arguments : String,
) -> String {
  let document = @json.parse(arguments)
  let rel = json_string_arg(document, "path")
  let content = json_string_arg(document, "content")
  guard rel != "" else { fail("path is required") }
  guard confirm_write(confirm, "写入 ", rel) else {
    return "change declined by user"
  }
  let path = safe_path(root, rel)
  @fs.write_file(path, content, create_mode=@fs.CreateMode::CreateOrTruncate)
  "wrote \{rel}"
}

///|
async fn multi_edit_tool(
  root : String,
  confirm : WriteConfirm,
  arguments : String,
) -> String {
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
    let file = json_string_arg(item, "file")
    let old_string = json_string_arg(item, "old_string")
    let new_string = json_string_arg(item, "new_string")
    let start_line = parse_int_or(json_string_arg(item, "start_line"), 1)
    let end_line = parse_int_or(json_string_arg(item, "end_line"), 0)
    guard file != "" else { fail("each edit requires a file") }
    edits.push({ file, old_string, new_string, start_line, end_line })
  }
  guard edits.length() > 0 else { fail("edits must not be empty") }
  let original : Map[String, String] = Map([])
  for edit in edits {
    if original.get(edit.file) is None {
      let path = safe_path(root, edit.file)
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
  guard confirm_write(confirm, "", "批量编辑") else {
    return "change declined by user"
  }
  let mut changed = 0
  for file, new_content in results {
    if original[file] != new_content {
      @fs.write_file(
        safe_path(root, file),
        new_content,
        create_mode=@fs.CreateMode::CreateOrTruncate,
      )
      changed += 1
    }
  }
  "applied \{edits.length()} edit(s) to \{changed} file(s)"
}

///|
async fn remove_tool(
  root : String,
  confirm : WriteConfirm,
  arguments : String,
) -> String {
  let document = @json.parse(arguments)
  let rel = json_string_arg(document, "path")
  guard rel != "" else { fail("path is required") }
  guard confirm_write(confirm, "删除 ", rel) else {
    return "change declined by user"
  }
  let path = safe_path(root, rel)
  guard @fs.kind(path) is @fs.FileKind::Regular else {
    fail("remove only supports regular files: \{rel}")
  }
  @fs.remove(path)
  "removed \{rel}"
}

///|
// 共享写工具集：write_file / multi_edit / remove，全部限定在 Workspace 根目录内。
pub fn write_tools(
  ws : Workspace,
  confirm : WriteConfirm,
) -> Array[@tools.Tool] {
  [
    {
      schema: {
        name: "write_file",
        description: "Overwrite a project file with its full new content. Prefer multi_edit for precise edits; use write_file for whole-file replacements or new files.",
        parameters: @tools.object_schema(
          {
            "path": @tools.string_field("Relative file path"),
            "content": @tools.string_field("Complete new file content"),
          },
          ["path", "content"],
        ),
      },
      execute: async fn(arguments) {
        write_file_tool(ws.get_root(), confirm, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "multi_edit",
        description: "Apply exact line-anchored replacements across one or more files in one validated batch. Each edit is {file, old_string, new_string, start_line, end_line}: old_string must match exactly once within the given 1-based line range; use an empty old_string to insert new_string at the start of start_line. The whole batch is atomic and must pass moonc syncheck before anything is written.",
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
        multi_edit_tool(ws.get_root(), confirm, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "remove",
        description: "Delete a regular file from the project.",
        parameters: @tools.object_schema(
          { "path": @tools.string_field("Relative file path to delete") },
          ["path"],
        ),
      },
      execute: async fn(arguments) {
        remove_tool(ws.get_root(), confirm, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
  ]
}

///|
// 从工具参数 JSON 中读取字符串字段。
fn json_string_arg(document : Json, key : String) -> String {
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
fn parse_int_or(s : String, default : Int) -> Int {
  @string.parse_int(s) catch {
    _ => default
  }
}
