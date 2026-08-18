///|
// 写操作前的确认方式。
pub(all) enum WriteConfirm {
  // 每次写入前在 stdin 询问 y/N
  Prompt
  // 直接应用，不询问
  Auto
}

///|
// Paths that must never be changed by an agent. Keep this aligned with the
// workspace readers so a hidden/generated file cannot be reached through a
// write-only path.
fn is_protected_write_path(rel : String) -> Bool {
  let normalized = rel.replace_all(old="\\", new="/")
  let segments = normalized
    .split("/")
    .filter(fn(segment) { segment != "" })
    .map(fn(segment) { segment.to_owned().to_lower() })
    .to_array()
  guard segments.length() > 0 else { return true }
  let ignored = [
    ".git",
    ".mooncakes",
    ".moonsage",
    ".cache",
    "_build",
    "_build.bak",
    "node_modules",
    "target",
  ]
  for segment in segments {
    if ignored.contains(segment) || segment.has_prefix("_audit_ws_") {
      return true
    }
  }
  let filename = segments[segments.length() - 1]
  filename == ".env" || filename.has_prefix(".env.")
}

///|
// Reject symlinks in every existing component. A lexical safe-path check is
// insufficient when an in-workspace directory points outside the workspace.
async fn checked_write_path(
  root : String,
  rel : String,
  require_file? : Bool = false,
) -> String {
  guard !is_protected_write_path(rel) else {
    fail("path is protected: \{rel}")
  }
  let target = @util.safe_path(root, rel)
  let normalized = rel.replace_all(old="\\", new="/")
  let segments = normalized.split("/").filter(fn(segment) {
    segment != "" && segment != "."
  }).map(fn(segment) { segment.to_owned() }).to_array()
  let mut current = root.trim_end(chars="\\/").to_owned()
  for index, segment in segments {
    current = current + "/" + segment
    let kind = @fs.kind(current, follow_symlink=false) catch {
      _ => Unknown
    }
    guard !(kind is SymLink) else {
      fail("symbolic links are not writable: \{rel}")
    }
    if index + 1 < segments.length() && !(kind is Unknown) {
      guard kind is Directory else {
        fail("write path contains a non-directory component: \{rel}")
      }
    }
  }
  if require_file {
    guard @fs.kind(target, follow_symlink=false) is Regular else {
      fail("operation only supports regular files: \{rel}")
    }
  }
  target
}

///|
// 修改后需要跑语法门校验的源码文件。
fn is_syncheck_source(rel : String) -> Bool {
  let base = @util.basename(rel)
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
    let file = tmp + "/" + @util.basename(rel)
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
      fail("\{rel} 修改后无法通过语法检查:\n\{err.text()}")
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
  ws : Workspace,
  confirm : WriteConfirm,
  arguments : String,
) -> String {
  let document = @json.parse(arguments)
  let rel = @util.json_string_arg(document, "path")
  let content = @util.json_string_arg(document, "content")
  guard rel != "" else { fail("path is required") }
  let root = ws.get_root()
  let path = checked_write_path(root, rel)
  // 与 multi_edit 一致:源码文件先过语法门再询问确认,避免确认一个注定失败的写入。
  if is_syncheck_source(rel) {
    ignore(syncheck_content(content, rel))
  }
  let original_opt = try {
    if @fs.kind(path) is @fs.FileKind::Regular {
      Some(@fs.read_file(path).text())
    } else {
      None
    }
  } catch {
    _ => None
  }
  let original = match original_opt {
    Some(s) => s
    None => ""
  }
  if confirm is Prompt {
    preview_diff(rel, original, content)
  }
  guard confirm_write(confirm, "写入 ", rel) else {
    return "change declined by user"
  }
  ws.push_undo(rel, original_opt)
  @fs.write_file(path, content, create_mode=@fs.CreateMode::CreateOrTruncate)
  "wrote \{rel}"
}

///|
async fn multi_edit_tool(
  ws : Workspace,
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
    let file = @util.json_string_arg(item, "file")
    let old_string = @util.json_string_arg(item, "old_string")
    let new_string = @util.json_string_arg(item, "new_string")
    let start_line = @util.parse_int_or(
      @util.json_string_arg(item, "start_line"),
      1,
    )
    let end_line = @util.parse_int_or(
      @util.json_string_arg(item, "end_line"),
      0,
    )
    guard file != "" else { fail("each edit requires a file") }
    edits.push({ file, old_string, new_string, start_line, end_line })
  }
  guard edits.length() > 0 else { fail("edits must not be empty") }
  let root = ws.get_root()
  let original : Map[String, String] = Map([])
  for edit in edits {
    if original.get(edit.file) is None {
      let path = checked_write_path(root, edit.file, require_file=true)
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
  if confirm is Prompt {
    for file, new_content in results {
      if original[file] != new_content {
        preview_diff(file, original[file], new_content)
      }
    }
  }
  guard confirm_write(confirm, "", "批量编辑") else {
    return "change declined by user"
  }
  let mut changed = 0
  for file, new_content in results {
    if original[file] != new_content {
      ws.push_undo(file, Some(original[file]))
      @fs.write_file(
        checked_write_path(root, file, require_file=true),
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
  ws : Workspace,
  confirm : WriteConfirm,
  arguments : String,
) -> String {
  let document = @json.parse(arguments)
  let rel = @util.json_string_arg(document, "path")
  guard rel != "" else { fail("path is required") }
  let path = checked_write_path(ws.get_root(), rel, require_file=true)
  let content = Some(@fs.read_file(path).text()) catch { _ => None }
  if confirm is Prompt {
    match content {
      Some(c) => preview_diff(rel, c, "")
      None => ()
    }
  }
  guard confirm_write(confirm, "删除 ", rel) else {
    return "change declined by user"
  }
  ws.push_undo(rel, content)
  @fs.remove(path)
  "removed \{rel}"
}

///|
// Prompt 确认前在终端展示简洁 unified diff(单文件最多 50 行),让用户
// 看到将要发生的变更。预览失败不阻塞写入(仅提示能力)。
async fn preview_diff(rel : String, original : String, new : String) -> Unit {
  let tmp = @fs.tmpdir(prefix="moonsage-diff-")
  try {
    let old_path = tmp + "/old"
    let new_path = tmp + "/new"
    let _ = @fs.write_file(
      old_path,
      original,
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let _ = @fs.write_file(
      new_path,
      new,
      create_mode=@fs.CreateMode::CreateOrTruncate,
    )
    let (exit, out, _) = @process.collect_output(
      "git",
      [
        "diff",
        "--no-index",
        "--label",
        "a/\{rel}",
        "--label",
        "b/\{rel}",
        "--",
        old_path,
        new_path,
      ],
      no_console_window=true,
    )
    // git diff --no-index:0 表示无差异,1 表示有差异,其他为 git 不可用。
    if exit == 0 || exit == 1 {
      let text = out.text() catch { _ => "" }
      if text != "" {
        let lines = text.split("\n").to_array()
        let limit = if lines.length() > 50 { 50 } else { lines.length() }
        @stdio.stdout.write("\n")
        for i = 0; i < limit; i = i + 1 {
          @stdio.stdout.write(lines[i] + "\n")
        }
        if lines.length() > 50 {
          @stdio.stdout.write("... (diff truncated)\n")
        }
        @stdio.stdout.write("\n")
      }
    }
  } catch {
    _ => ()
  }
  @fs.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
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
        write_file_tool(ws, confirm, arguments) catch {
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
        multi_edit_tool(ws, confirm, arguments) catch {
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
        remove_tool(ws, confirm, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
  ]
}
