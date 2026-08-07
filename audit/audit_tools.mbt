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
// 组装审计工具集：只读工具来自共享 local 包；修复模式下追加共享写工具
// （write_file / multi_edit / remove），确认方式映射为共享 WriteConfirm。
fn audit_tools(ctx : AuditContext) -> Array[@tools.Tool] {
  let base = @local.local_tools(ctx.project_dir)
  if ctx.fix {
    let confirm = if ctx.confirm is ConfirmPrompt {
      @editing.Prompt
    } else {
      @editing.Auto
    }
    base + @editing.write_tools(ctx.project_dir, confirm)
  } else {
    base
  }
}
