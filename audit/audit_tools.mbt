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
  @fs.write_file(path, content)
  "wrote \{rel}"
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
    ]
  } else {
    base
  }
}
