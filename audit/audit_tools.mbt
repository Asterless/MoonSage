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
// 自检工具：修复 Agent 必须在结束前调用一次，显式声明修复完成度。
// 结果会进入审计证据，未声明或声明非 done 的审计会挂起等待人工确认。
fn submit_audit_status_tool() -> @tools.Tool {
  {
    schema: {
      name: "submit_audit_status",
      description: "声明本次审计修复的自检结论，必须在结束前调用一次。status 为 done（全部修复完成）、partial（部分修复，仍有未解决问题）或 blocked（遇到无法解决的问题）；summary 用一句话说明遗留问题。",
      parameters: @tools.object_schema(
        {
          "status": @tools.string_field("done / partial / blocked"),
          "summary": @tools.string_field(
            "自检摘要：说明遗留问题或确认全部完成",
          ),
        },
        ["status", "summary"],
      ),
    },
    execute: async fn(arguments) {
      let document = @json.parse(arguments) catch {
        _ =>
          return @tools.error_json(
            "submit_audit_status requires JSON arguments",
          )
      }
      match document {
        Object(fields) => {
          let status = match fields.get("status") {
            Some(String(value)) => value
            _ => return @tools.error_json("missing string argument: status")
          }
          if status != "done" && status != "partial" && status != "blocked" {
            return @tools.error_json(
              "status must be one of done, partial or blocked",
            )
          }
          let summary = match fields.get("summary") {
            Some(String(value)) => value
            _ => ""
          }
          Json::object({
            "status": Json::string(status),
            "summary": Json::string(summary),
          }).stringify()
        }
        _ => @tools.error_json("submit_audit_status requires a JSON object")
      }
    },
  }
}

///|
// 组装审计工具集：只读工具来自共享 local 包；修复模式下追加共享写工具
// （write_file / multi_edit / remove），确认方式映射为共享 WriteConfirm。
fn audit_tools(
  ctx : AuditContext,
  restricted_moon? : Bool = false,
) -> Array[@tools.Tool] {
  let ws = @editing.Workspace::new(ctx.project_dir)
  let available = @local.local_tools(ws)
  // Mode 1 runs against untrusted repositories. Replace the general-purpose
  // `run_moon` tool with the controller-owned check/build/test-only variant;
  // ordinary interactive audits keep their existing tool surface.
  let base = if restricted_moon {
    available.filter(fn(tool) { tool.schema.name != "run_moon" }) +
    @local.verification_tools(ws)
  } else {
    available
  }
  if ctx.fix {
    let confirm = if ctx.confirm is ConfirmPrompt {
      @editing.Prompt
    } else {
      @editing.Auto
    }
    base + @editing.write_tools(ws, confirm) + [submit_audit_status_tool()]
  } else {
    base
  }
}
