///|
/// Permission policy for a workspace-driven task. The policy is deliberately
/// kept separate from the Agent runtime so callers can persist it alongside a
/// task without exposing runtime implementation details.
pub(all) enum WorkspacePermission {
  ReadOnly
  ControlledWrite
  FullAuto
} derive(Eq, Debug)

///|
pub fn workspace_permission_from_string(value : String) -> WorkspacePermission {
  match value.trim().to_lower() {
    "read-only" | "readonly" | "read_only" | "ro" => ReadOnly
    "full-auto" | "fullauto" | "full_auto" | "auto" => FullAuto
    _ => ControlledWrite
  }
}

///|
fn workspace_permission_name(permission : WorkspacePermission) -> String {
  match permission {
    ReadOnly => "read-only"
    ControlledWrite => "controlled-write"
    FullAuto => "full-auto"
  }
}

///|
/// Stable wire representation for task persistence and CLI bridges.
pub fn workspace_permission_to_string(
  permission : WorkspacePermission,
) -> String {
  workspace_permission_name(permission)
}

///|
fn workspace_system_prompt(
  root : String,
  permission : WorkspacePermission,
) -> String {
  let policy = workspace_permission_name(permission)
  (
    #|You are MoonSage operating as a workspace-driven coding agent.
    #|The task is the user's objective; do not treat this as a general chat.
    #|Work from the selected workspace using the local file tools. Inspect
    #|relevant files before proposing or applying changes, keep paths relative
    #|to the workspace, and report concrete files and validation results.
    #|Use list_project_files, grep_files and read_file to gather context.
    #|For edits, prefer multi_edit for precise changes and write_file only when
    #|a complete replacement is necessary. Never access paths outside the
    #|workspace or claim a change was applied without tool confirmation.
  ) +
  "\nWorkspace root: " +
  root +
  "\nPermission policy: " +
  policy +
  "\n"
}

///|
/// Build the local task agent. `ask` remains backed by the research agent;
/// this constructor is the workspace-first entry point used by task runners.
pub fn workspace_agent(
  root : String,
  permission : WorkspacePermission,
  project_instructions : String,
) -> Agent {
  let workspace = @editing.Workspace::new(root)
  let workspace_tools = @local.local_tools(workspace)
  let workspace_tools = if permission is ReadOnly {
    // `run_moon` can create build artefacts, so it is not exposed in a
    // genuinely read-only task. Git inspection and file tools remain usable.
    workspace_tools.filter(fn(tool) { tool.schema.name != "run_moon" })
  } else {
    workspace_tools
  }
  let write = match permission {
    ReadOnly => []
    ControlledWrite => @editing.write_tools(workspace, Prompt)
    FullAuto => @editing.write_tools(workspace, Auto)
  }
  {
    system_prompt: workspace_system_prompt(root, permission) +
    project_instructions,
    tools: workspace_tools + write,
    max_tool_calls: 32,
    max_rounds: 10,
    max_tokens: 2400,
  }
}
