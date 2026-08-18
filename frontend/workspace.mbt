///|
struct WorkspaceChange {
  path : String
  old_path : String
  index : String
  worktree : String
  staged : Bool
  unstaged : Bool
  untracked : Bool
  conflicted : Bool
  rename : Bool
  copy : Bool
} derive(Eq)

///|
// A registry entry is intentionally separate from the currently-open editor
// state. This lets the UI keep a complete Local/Worktree list while a file is
// being edited and makes switching workspaces an explicit operation.
struct WorkspaceEntry {
  id : String
  name : String
  path : String
  kind : String
  mode : String
  managed : Bool
  lifecycle : String
  branch : String
  detached : Bool
  pinned : Bool
  status : String
  revision : String
  source_id : String
  owner_task_id : String
  owner_session_id : String
  eligible_for_cleanup : Bool
} derive(Debug, Eq)

///|
struct WorkspaceFileEntry {
  path : String
  relative_path : String
} derive(Debug, Eq)

///|
struct WorkspaceFileGroup {
  key : String
  label : String
  files : Array[WorkspaceFileEntry]
} derive(Debug, Eq)

///|
struct WorkspaceModel {
  open : Bool
  entries : Array[WorkspaceEntry]
  id : String
  name : String
  tab : String
  root : String
  kind : String
  mode : String
  lifecycle : String
  branch : String
  detached : Bool
  pinned : Bool
  status : String
  session_id : String
  revision : String
  file_revision : String
  files : Array[String]
  filter : String
  expanded_groups : Array[String]
  selected_path : String
  content : String
  saved_content : String
  line_endings : String
  changes : Array[WorkspaceChange]
  diff_scope : String
  diff : String
  commit_message : String
  loading : Bool
  notice : String
  error : String
  pending_action : String
} derive(Eq)

///|
fn initial_workspace() -> WorkspaceModel {
  {
    open: false,
    entries: [],
    id: "",
    name: "",
    tab: "files",
    root: "",
    kind: "local",
    mode: "local",
    lifecycle: "local",
    branch: "",
    detached: false,
    pinned: false,
    status: "ready",
    session_id: "",
    revision: "",
    file_revision: "",
    files: [],
    filter: "",
    expanded_groups: [""],
    selected_path: "",
    content: "",
    saved_content: "",
    line_endings: "lf",
    changes: [],
    diff_scope: "working",
    diff: "",
    commit_message: "",
    loading: false,
    notice: "",
    error: "",
    pending_action: "",
  }
}

///|
fn json_fields(source : String) -> Map[String, Json]? {
  let document = @json.parse(source) catch { _ => return None }
  match document {
    Object(fields) => Some(fields)
    _ => None
  }
}

///|
fn json_string_field(fields : Map[String, Json], name : String) -> String {
  match fields.get(name) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn json_bool_field(
  fields : Map[String, Json],
  name : String,
  default : Bool,
) -> Bool {
  match fields.get(name) {
    Some(True) => true
    Some(False) => false
    _ => default
  }
}

///|
fn decode_workspace_entry(value : Json) -> WorkspaceEntry? {
  guard value is Object(fields) else { return None }
  guard fields.get("id") is Some(String(id)) else { return None }
  let raw_kind = json_string_field(fields, "kind")
  let managed = json_bool_field(fields, "managed", raw_kind == "worktree")
  let kind = if raw_kind == "worktree" || managed {
    "worktree"
  } else {
    "local"
  }
  let raw_mode = json_string_field(fields, "mode")
  Some({
    id,
    name: json_string_field(fields, "name"),
    path: match fields.get("path") {
      Some(String(path)) => path
      _ => json_string_field(fields, "root")
    },
    kind,
    mode: if raw_mode == "managed" || kind == "worktree" {
      "managed"
    } else {
      "local"
    },
    managed,
    lifecycle: json_string_field(fields, "lifecycle"),
    branch: json_string_field(fields, "branch"),
    detached: json_bool_field(fields, "detached", false),
    pinned: json_bool_field(fields, "pinned", false),
    status: json_string_field(fields, "status"),
    revision: json_string_field(fields, "revision"),
    source_id: json_string_field(fields, "source_id"),
    owner_task_id: json_string_field(fields, "owner_task_id"),
    owner_session_id: json_string_field(fields, "owner_session_id"),
    eligible_for_cleanup: json_bool_field(fields, "eligible_for_cleanup", false),
  })
}

///|
fn decode_workspace_entries(source : String) -> Array[WorkspaceEntry] {
  guard json_fields(source) is Some(fields) else { return [] }
  match fields.get("workspaces") {
    Some(Array(items)) => items.filter_map(decode_workspace_entry)
    _ =>
      match fields.get("workspace") {
        Some(value) =>
          match decode_workspace_entry(value) {
            Some(entry) => [entry]
            None => []
          }
        None => []
      }
  }
}

///|
fn workspace_entry_for(
  entries : Array[WorkspaceEntry],
  id : String,
) -> WorkspaceEntry? {
  for entry in entries {
    if entry.id == id {
      return Some(entry)
    }
  }
  None
}

///|
fn workspace_apply_entry(
  workspace : WorkspaceModel,
  entry : WorkspaceEntry,
) -> WorkspaceModel {
  let switching = entry.id != workspace.id
  {
    ..workspace,
    id: entry.id,
    name: entry.name,
    root: entry.path,
    kind: entry.kind,
    mode: if entry.mode == "managed" {
      "managed"
    } else {
      "local"
    },
    lifecycle: if entry.lifecycle == "" {
      if entry.kind == "worktree" {
        "temporary"
      } else {
        "local"
      }
    } else {
      entry.lifecycle
    },
    branch: entry.branch,
    detached: entry.detached,
    pinned: entry.pinned,
    status: if entry.status == "" {
      "ready"
    } else {
      entry.status
    },
    revision: if entry.revision != "" {
      entry.revision
    } else if switching {
      ""
    } else {
      workspace.revision
    },
    file_revision: if switching {
      ""
    } else {
      workspace.file_revision
    },
    files: if switching {
      []
    } else {
      workspace.files
    },
    expanded_groups: if switching {
      [""]
    } else {
      workspace.expanded_groups
    },
    selected_path: if switching {
      ""
    } else {
      workspace.selected_path
    },
    content: if switching {
      ""
    } else {
      workspace.content
    },
    saved_content: if switching {
      ""
    } else {
      workspace.saved_content
    },
    line_endings: if switching {
      "lf"
    } else {
      workspace.line_endings
    },
    changes: if switching {
      []
    } else {
      workspace.changes
    },
    diff: if switching {
      ""
    } else {
      workspace.diff
    },
    pending_action: "",
  }
}

///|
fn decode_workspace_tree(source : String) -> (String, Array[String])? {
  guard json_fields(source) is Some(fields) else { return None }
  guard fields.get("files") is Some(Array(files)) else { return None }
  let paths : Array[String] = []
  for entry in files {
    if entry is String(path) {
      paths.push(path)
    }
  }
  Some((json_string_field(fields, "root"), paths))
}

///|
fn decode_workspace_registry(source : String) -> (String, String)? {
  let entries = decode_workspace_entries(source)
  if entries.is_empty() {
    match json_fields(source) {
      Some(fields) if fields.get("workspaces") is Some(Array(_)) =>
        Some(("", ""))
      _ => None
    }
  } else {
    Some((entries[0].id, entries[0].name))
  }
}

///|
fn decode_workspace_pick(source : String) -> (String, String)? {
  guard json_fields(source) is Some(fields) else { return None }
  guard fields.get("workspace") is Some(Object(workspace)) else { return None }
  guard workspace.get("id") is Some(String(id)) else { return None }
  Some((id, json_string_field(workspace, "name")))
}

///|
fn workspace_pick_cancelled(source : String) -> Bool {
  guard json_fields(source) is Some(fields) else { return false }
  fields.get("cancelled") is Some(True)
}

///|
fn decode_workspace_file(source : String) -> (String, String)? {
  guard json_fields(source) is Some(fields) else { return None }
  match fields.get("content") {
    Some(String(content)) => {
      let line_endings = match fields.get("line_endings") {
        Some(String(style)) => style
        _ => "lf"
      }
      Some((content, line_endings))
    }
    _ => None
  }
}

///|
fn decode_workspace_file_revision(source : String) -> String {
  match json_fields(source) {
    Some(fields) => json_string_field(fields, "revision")
    None => ""
  }
}

///|
fn decode_workspace_changes(value : Json) -> Array[WorkspaceChange] {
  guard value is Array(items) else { return [] }
  let changes : Array[WorkspaceChange] = []
  for item in items {
    guard item is Object(fields) else { continue }
    let boolean = fn(name) {
      match fields.get(name) {
        Some(True) => true
        Some(False) => false
        _ => false
      }
    }
    changes.push({
      path: json_string_field(fields, "path"),
      old_path: json_string_field(fields, "old_path"),
      index: json_string_field(fields, "index"),
      worktree: json_string_field(fields, "worktree"),
      staged: boolean("staged"),
      unstaged: boolean("unstaged"),
      untracked: boolean("untracked"),
      conflicted: boolean("conflicted"),
      rename: boolean("rename"),
      copy: boolean("copy"),
    })
  }
  changes
}

///|
fn apply_workspace_status(
  workspace : WorkspaceModel,
  source : String,
) -> WorkspaceModel? {
  guard json_fields(source) is Some(fields) else { return None }
  let changes = match fields.get("changes") {
    Some(value) => decode_workspace_changes(value)
    None => []
  }
  Some({
    ..workspace,
    branch: json_string_field(fields, "branch"),
    detached: json_bool_field(fields, "detached", false),
    revision: json_string_field(fields, "revision"),
    changes,
    loading: false,
    error: "",
  })
}

///|
fn decode_workspace_diff(source : String) -> String? {
  guard json_fields(source) is Some(fields) else { return None }
  match fields.get("diff") {
    Some(String(diff)) => Some(diff)
    _ => None
  }
}

///|
fn workspace_changed(workspace : WorkspaceModel) -> Bool {
  workspace.selected_path != "" && workspace.content != workspace.saved_content
}

///|
fn change_for_path(
  workspace : WorkspaceModel,
  path : String,
) -> WorkspaceChange? {
  for change in workspace.changes {
    if change.path == path {
      return Some(change)
    }
  }
  None
}

///|
fn change_label(change : WorkspaceChange) -> String {
  if change.untracked {
    "U"
  } else if change.staged && change.unstaged {
    change.index + change.worktree
  } else if change.staged {
    change.index
  } else {
    change.worktree
  }
}

///|
fn workspace_path_group(path : String) -> (String, String) {
  match path.find("/") {
    Some(index) => (path[:index].to_owned(), path[index + 1:].to_owned())
    None => ("", path)
  }
}

///|
fn workspace_file_groups(
  paths : Array[String],
  filter : String,
) -> Array[WorkspaceFileGroup] {
  let needle = filter.trim().to_lower()
  let root_files : Array[WorkspaceFileEntry] = []
  let group_order : Array[String] = []
  let grouped : Map[String, Array[WorkspaceFileEntry]] = Map([])
  for path in paths {
    if needle != "" && !path.to_lower().contains(needle) {
      continue
    }
    let (key, relative_path) = workspace_path_group(path)
    let entry : WorkspaceFileEntry = { path, relative_path }
    if key == "" {
      root_files.push(entry)
    } else {
      match grouped.get(key) {
        Some(entries) => entries.push(entry)
        None => {
          grouped[key] = [entry]
          group_order.push(key)
        }
      }
    }
  }
  let groups : Array[WorkspaceFileGroup] = []
  if !root_files.is_empty() {
    groups.push({ key: "", label: "根目录", files: root_files })
  }
  for key in group_order {
    groups.push({ key, label: key, files: grouped[key] })
  }
  groups
}

///|
fn workspace_group_expanded(workspace : WorkspaceModel, key : String) -> Bool {
  if !workspace.filter.trim().is_empty() {
    return true
  }
  if workspace.selected_path != "" &&
    workspace_path_group(workspace.selected_path).0 == key {
    return true
  }
  workspace.expanded_groups.any(group => group == key)
}

///|
fn toggle_workspace_group(
  groups : Array[String],
  key : String,
) -> Array[String] {
  let next : Array[String] = []
  let mut found = false
  for group in groups {
    if group == key {
      found = true
    } else {
      next.push(group)
    }
  }
  if !found {
    next.push(key)
  }
  next
}

///|
fn workspace_tabs(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  let tabs = [("files", "文件"), ("diff", "Diff"), ("git", "Git")]
  nav(
    class="workspace-tabs",
    attrs=@html.Attrs::build().role("tablist").aria_label("工作区视图"),
    [
      for tab in tabs => {
        let active = workspace.tab == tab.0
        button(
          class=if active { "workspace-tab active" } else { "workspace-tab" },
          type_="button",
          attrs=@html.Attrs::build()
            .role("tab")
            .aria_selected(if active { "true" } else { "false" }),
          on_click=emit(WorkspaceTabSelected(tab.0)),
          tab.1,
        )
      }
    ],
  )
}

///|
fn workspace_file_list(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  let groups = workspace_file_groups(workspace.files, workspace.filter)
  let visible_count = groups.fold(init=0, (count, group) => {
    count + group.files.length()
  })
  let dirty = workspace_changed(workspace)
  div(class="workspace-file-browser", [
    input(
      class="workspace-filter",
      value=workspace.filter,
      placeholder="筛选文件",
      attrs=@html.Attrs::build().aria_label("筛选工作区文件"),
      on_input=emit.map(value => WorkspaceFilterChanged(value)),
    ),
    div(class="workspace-file-count", "\{visible_count} 个文件"),
    nav(
      class="workspace-file-list",
      attrs=@html.Attrs::build().aria_label("工作区文件"),
      [
        for group in groups => {
          let expanded = workspace_group_expanded(workspace, group.key)
          div(class="workspace-file-group", [
            button(
              class="workspace-group-toggle",
              type_="button",
              title=if expanded {
                "折叠 \{group.label}"
              } else {
                "展开 \{group.label}"
              },
              attrs=@html.Attrs::build().aria_expanded(
                if expanded {
                  "true"
                } else {
                  "false"
                },
              ),
              on_click=emit(WorkspaceToggleGroup(group.key)),
              [
                span(
                  class=if expanded {
                    "group-chevron expanded"
                  } else {
                    "group-chevron"
                  },
                  [icon("chevron-right")],
                ),
                icon(if expanded { "folder-open" } else { "folder" }),
                span(class="workspace-group-label", group.label),
                span(
                  class="workspace-group-count",
                  group.files.length().to_string(),
                ),
              ],
            ),
            if expanded {
              div(
                class="workspace-group-files",
                attrs=@html.Attrs::build().role("group"),
                [
                  for entry in group.files => {
                    let active = entry.path == workspace.selected_path
                    let status = change_for_path(workspace, entry.path)
                    button(
                      class=if active {
                        "workspace-file active"
                      } else {
                        "workspace-file"
                      },
                      type_="button",
                      title=entry.path,
                      disabled=dirty && !active,
                      attrs=@html.Attrs::build().aria_current(
                        if active {
                          "location"
                        } else {
                          "false"
                        },
                      ),
                      on_click=emit(WorkspaceSelectFile(entry.path)),
                      [
                        span(class="workspace-file-icon", [icon("file-code-2")]),
                        span(class="workspace-file-path", entry.relative_path),
                        match status {
                          Some(change) =>
                            span(
                              class="workspace-file-status",
                              change_label(change),
                            )
                          None => span(class="workspace-file-status empty", "")
                        },
                      ],
                    )
                  }
                ],
              )
            } else {
              div(class="workspace-group-placeholder", "")
            },
          ])
        }
      ],
    ),
  ])
}

///|
fn workspace_editor(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  if workspace.selected_path == "" {
    div(class="workspace-editor-empty", [
      span(class="workspace-empty-mark", [icon("file-code-2")]),
      p("从文件列表选择文件"),
    ])
  } else {
    let dirty = workspace_changed(workspace)
    div(class="workspace-editor", [
      div(class="workspace-editor-bar", [
        div(class="workspace-editor-title", [
          span(class=if dirty { "dirty-dot visible" } else { "dirty-dot" }, ""),
          span(title=workspace.selected_path, workspace.selected_path),
        ]),
        button(
          class="workspace-primary-button",
          type_="button",
          title="保存文件",
          disabled=!dirty || workspace.loading,
          on_click=emit(WorkspaceSaveFile),
          [icon("save"), span("保存")],
        ),
      ]),
      textarea(
        class="workspace-code-editor",
        value=workspace.content,
        attrs=@html.Attrs::build()
          .aria_label("编辑 " + workspace.selected_path)
          .spellcheck(false),
        on_input=emit.map(value => WorkspaceContentChanged(value)),
        "",
      ),
    ])
  }
}

///|
fn workspace_files_view(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  div(
    class="workspace-files-view",
    attrs=@html.Attrs::build().role("tabpanel"),
    [workspace_file_list(workspace, emit), workspace_editor(workspace, emit)],
  )
}

///|
fn diff_line_view(line : String) -> Html {
  let kind = if line.has_prefix("+++") || line.has_prefix("---") {
    "diff-line meta"
  } else if line.has_prefix("+") {
    "diff-line added"
  } else if line.has_prefix("-") {
    "diff-line removed"
  } else if line.has_prefix("@@") ||
    line.has_prefix("diff ") ||
    line.has_prefix("index ") {
    "diff-line header"
  } else {
    "diff-line"
  }
  span(class=kind, line + "\n")
}

///|
fn workspace_diff_view(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  div(
    class="workspace-diff-view",
    attrs=@html.Attrs::build().role("tabpanel"),
    [
      div(class="workspace-view-toolbar", [
        div(class="segmented-control", [
          button(
            class=if workspace.diff_scope == "working" { "active" } else { "" },
            type_="button",
            attrs=@html.Attrs::build().aria_pressed(
              if workspace.diff_scope == "working" {
                "true"
              } else {
                "false"
              },
            ),
            on_click=emit(WorkspaceDiffScopeChanged("working")),
            "工作区",
          ),
          button(
            class=if workspace.diff_scope == "staged" { "active" } else { "" },
            type_="button",
            attrs=@html.Attrs::build().aria_pressed(
              if workspace.diff_scope == "staged" {
                "true"
              } else {
                "false"
              },
            ),
            on_click=emit(WorkspaceDiffScopeChanged("staged")),
            "暂存区",
          ),
        ]),
        button(
          class="workspace-icon-button",
          type_="button",
          title="刷新 Diff",
          attrs=@html.Attrs::build().aria_label("刷新 Diff"),
          on_click=emit(WorkspaceRefresh),
          icon("refresh-cw"),
        ),
      ]),
      if workspace.diff == "" && !workspace.loading {
        div(class="workspace-editor-empty", [
          span(class="workspace-empty-mark", [icon("file-diff")]),
          p(
            if workspace.diff_scope == "working" {
              "工作区没有差异"
            } else {
              "暂存区没有差异"
            },
          ),
        ])
      } else {
        pre(
          class="workspace-diff",
          [
            for line in workspace.diff.split("\n") => {
              diff_line_view(line.to_owned())
            }
          ],
        )
      },
    ],
  )
}

///|
fn workspace_change_row(change : WorkspaceChange, emit : Emit[Msg]) -> Html {
  div(class="workspace-change-row", [
    span(class="workspace-change-status", change_label(change)),
    span(class="workspace-change-path", title=change.path, change.path),
    if change.unstaged {
      button(
        class="workspace-row-action",
        type_="button",
        title="暂存文件",
        attrs=@html.Attrs::build().aria_label("暂存 " + change.path),
        on_click=emit(WorkspaceStage(change.path)),
        icon("plus"),
      )
    } else {
      span(class="workspace-row-action-placeholder", "")
    },
    if change.staged {
      button(
        class="workspace-row-action",
        type_="button",
        title="取消暂存",
        attrs=@html.Attrs::build().aria_label("取消暂存 " + change.path),
        on_click=emit(WorkspaceUnstage(change.path)),
        icon("minus"),
      )
    } else {
      span(class="workspace-row-action-placeholder", "")
    },
  ])
}

///|
fn workspace_git_view(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  let staged = workspace.changes.filter(change => change.staged)
  let unstaged = workspace.changes.filter(change => change.unstaged)
  div(class="workspace-git-view", attrs=@html.Attrs::build().role("tabpanel"), [
    div(class="workspace-view-toolbar", [
      div(class="branch-badge", [icon("git-branch"), span(workspace.branch)]),
      button(
        class="workspace-icon-button",
        type_="button",
        title="刷新 Git 状态",
        attrs=@html.Attrs::build().aria_label("刷新 Git 状态"),
        on_click=emit(WorkspaceRefresh),
        icon("refresh-cw"),
      ),
    ]),
    div(class="workspace-change-list", [
      div(
        class="workspace-change-heading",
        "暂存的更改 · \{staged.length()}",
      ),
      if staged.is_empty() {
        p(class="workspace-change-empty", "还没有暂存文件")
      } else {
        div([ for change in staged => workspace_change_row(change, emit) ])
      },
      div(
        class="workspace-change-heading",
        "工作区更改 · \{unstaged.length()}",
      ),
      if unstaged.is_empty() {
        p(class="workspace-change-empty", "工作区干净")
      } else {
        div([ for change in unstaged => workspace_change_row(change, emit) ])
      },
    ]),
    form(class="workspace-commit", on_submit=emit(WorkspaceCommit), [
      input(
        value=workspace.commit_message,
        placeholder="提交说明",
        attrs=@html.Attrs::build().aria_label("Git 提交说明").maxlength(200),
        on_input=emit.map(value => WorkspaceCommitMessageChanged(value)),
      ),
      button(
        class="workspace-primary-button",
        type_="submit",
        disabled=staged.is_empty() ||
          workspace.commit_message.trim().is_empty() ||
          workspace.loading,
        "提交",
      ),
    ]),
  ])
}

///|
fn workspace_entry_label(entry : WorkspaceEntry) -> String {
  let kind = if entry.kind == "worktree" { "Worktree" } else { "Local" }
  let lifecycle = if entry.lifecycle == "" {
    ""
  } else {
    " · " + entry.lifecycle
  }
  let branch = if entry.branch == "" {
    if entry.detached {
      " · detached"
    } else {
      ""
    }
  } else {
    " · " + entry.branch
  }
  "\{kind}\{lifecycle}\{branch}"
}

///|
fn workspace_handoff_target(workspace : WorkspaceModel) -> String {
  if workspace.kind != "worktree" {
    return ""
  }
  match workspace_entry_for(workspace.entries, workspace.id) {
    Some(entry) => entry.source_id
    None => ""
  }
}

///|
fn workspace_clear_entry(workspace : WorkspaceModel) -> WorkspaceModel {
  {
    ..workspace,
    entries: [],
    id: "",
    name: "",
    root: "",
    kind: "local",
    mode: "local",
    lifecycle: "local",
    branch: "",
    detached: false,
    pinned: false,
    status: "ready",
    revision: "",
    file_revision: "",
    files: [],
    expanded_groups: [""],
    selected_path: "",
    content: "",
    saved_content: "",
    line_endings: "lf",
    changes: [],
    diff: "",
    loading: false,
    notice: "",
    error: "",
    pending_action: "",
  }
}

///|
fn workspace_registry_view(
  workspace : WorkspaceModel,
  emit : Emit[Msg],
) -> Html {
  if workspace.entries.is_empty() {
    div(class="workspace-registry-empty", "没有已注册的工作区")
  } else {
    nav(
      class="workspace-registry",
      attrs=@html.Attrs::build().aria_label("工作区列表"),
      [
        for entry in workspace.entries => {
          let active = entry.id == workspace.id
          button(
            class=if active {
              "workspace-registry-item active"
            } else {
              "workspace-registry-item"
            },
            type_="button",
            disabled=workspace_changed(workspace) && !active,
            on_click=emit(WorkspaceSelect(entry.id)),
            [
              span(class="workspace-registry-name", entry.name),
              span(
                class="workspace-registry-meta",
                workspace_entry_label(entry),
              ),
              if entry.pinned {
                span(class="workspace-registry-pin", "置顶")
              } else {
                span(class="workspace-registry-pin", "")
              },
            ],
          )
        }
      ],
    )
  }
}

///|
fn workspace_dirty_guard(workspace : WorkspaceModel, emit : Emit[Msg]) -> Html {
  if workspace.pending_action == "" || !workspace_changed(workspace) {
    div(class="workspace-dirty-guard hidden", "")
  } else {
    div(class="workspace-dirty-guard", [
      span("当前文件有未保存修改"),
      button(
        type_="button",
        on_click=emit(WorkspaceDirtySave),
        "保存并继续",
      ),
      button(type_="button", on_click=emit(WorkspaceDirtyDiscard), "丢弃"),
      button(type_="button", on_click=emit(WorkspaceDirtyCancel), "取消"),
    ])
  }
}

///|
fn workspace_view(
  workspace : WorkspaceModel,
  modal : Bool,
  emit : Emit[Msg],
) -> Html {
  let handoff_target = workspace_handoff_target(workspace)
  let panel_attrs = @html.Attrs::build().aria_label("工作区")
  let panel_attrs = if modal {
    panel_attrs
    .role("dialog")
    .aria_modal("true")
    .on_keydown(event => {
      if event.key() == "Escape" {
        event.prevent_default()
        emit(ToggleWorkspace)
      } else {
        @rabbita.none
      }
    })
  } else {
    panel_attrs
  }
  aside(class="workspace-panel", attrs=panel_attrs, [
    header(class="workspace-header", [
      div(class="workspace-heading", [
        h1("工作区"),
        span(
          if workspace.name == "" {
            if workspace.root == "" {
              "尚未选择目录"
            } else {
              "本地仓库"
            }
          } else {
            workspace.name
          },
        ),
        span(
          class="workspace-mode-badge",
          if workspace.kind == "worktree" {
            "Worktree · \{workspace.lifecycle} · \{workspace.status}"
          } else {
            "Local · \{workspace.status}"
          },
        ),
      ]),
      button(
        class="workspace-icon-button",
        type_="button",
        title="选择工作区目录",
        attrs=@html.Attrs::build().aria_label("选择工作区目录"),
        on_click=emit(WorkspacePick),
        icon("folder-open"),
      ),
      button(
        class="workspace-icon-button",
        type_="button",
        title="关闭工作区",
        attrs=@html.Attrs::build().aria_label("关闭工作区"),
        on_click=emit(ToggleWorkspace),
        icon("panel-right-close"),
      ),
    ]),
    workspace_registry_view(workspace, emit),
    div(class="workspace-toolbar-actions", [
      button(
        class="workspace-small-button",
        type_="button",
        disabled=workspace.id == "" || workspace.kind != "local",
        on_click=emit(WorkspaceCreateWorktree),
        "创建 Worktree",
      ),
      button(
        class="workspace-small-button",
        type_="button",
        disabled=workspace.id == "",
        on_click=emit(WorkspacePin),
        if workspace.pinned {
          "取消置顶"
        } else {
          "置顶"
        },
      ),
      button(
        class="workspace-small-button",
        type_="button",
        disabled=handoff_target == "" || workspace.loading,
        on_click=emit(WorkspaceHandoff(handoff_target)),
        "移交改动",
      ),
      button(
        class="workspace-small-button danger",
        type_="button",
        disabled=workspace.id == "" || workspace.pinned,
        on_click=emit(WorkspaceDelete),
        "归档/删除",
      ),
    ]),
    workspace_dirty_guard(workspace, emit),
    workspace_tabs(workspace, emit),
    if workspace.error != "" {
      div(class="workspace-banner error", workspace.error)
    } else if workspace.notice != "" {
      div(class="workspace-banner success", workspace.notice)
    } else if workspace.loading {
      div(class="workspace-progress", "正在更新…")
    } else {
      div(class="workspace-progress placeholder", "")
    },
    match workspace.tab {
      "diff" => workspace_diff_view(workspace, emit)
      "git" => workspace_git_view(workspace, emit)
      _ => workspace_files_view(workspace, emit)
    },
  ])
}

///|
fn workspace_update(
  workspace : WorkspaceModel,
  msg : Msg,
  emit : Emit[Msg],
) -> (WorkspaceModel, Cmd)? {
  match msg {
    ToggleWorkspace =>
      if workspace.open {
        if workspace_changed(workspace) {
          Some(
            ({ ..workspace, pending_action: "close", error: "" }, @rabbita.none),
          )
        } else {
          Some(
            (
              { ..workspace, open: false, loading: false, pending_action: "" },
              after_render_focus(".workspace-toggle"),
            ),
          )
        }
      } else {
        let next = {
          ..workspace,
          open: true,
          loading: true,
          error: "",
          pending_action: "",
        }
        Some(
          (
            next,
            @cmd.batch([
              load_workspace_registry(emit),
              after_render_focus(".workspace-panel .workspace-icon-button"),
            ]),
          ),
        )
      }
    WorkspaceTabSelected(tab) => {
      let next = { ..workspace, tab, notice: "", error: "" }
      if tab == "diff" {
        Some(
          (
            { ..next, loading: true },
            load_workspace_diff(emit, next.id, next.diff_scope, ""),
          ),
        )
      } else if tab == "git" {
        Some(({ ..next, loading: true }, load_workspace_status(emit, next.id)))
      } else {
        Some(({ ..next, loading: false }, @rabbita.none))
      }
    }
    WorkspaceRegistryReceived(source) => {
      let entries = decode_workspace_entries(source)
      if entries.is_empty() {
        match decode_workspace_registry(source) {
          Some(_) =>
            Some(
              (
                workspace_clear_entry(workspace),
                persist_workspace_binding("", workspace.session_id),
              ),
            )
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "工作区注册信息格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      } else {
        let preferred = if workspace.id != "" {
          workspace_entry_for(entries, workspace.id)
        } else {
          let (stored_id, _) = load_workspace_binding()
          workspace_entry_for(entries, stored_id)
        }
        let selected = match preferred {
          Some(entry) => entry
          None => entries[0]
        }
        let next = workspace_apply_entry(
          { ..workspace, entries, error: "", loading: true },
          selected,
        )
        Some(
          (
            next,
            @cmd.batch([
              select_workspace(emit, next.id),
              persist_workspace_binding(next.id, next.session_id),
            ]),
          ),
        )
      }
    }
    WorkspaceRegistryReload =>
      Some(
        (
          { ..workspace, loading: true, error: "" },
          load_workspace_registry(emit),
        ),
      )
    WorkspaceSelect(id) =>
      if id == workspace.id {
        Some((workspace, @rabbita.none))
      } else if workspace_changed(workspace) {
        Some(({ ..workspace, pending_action: "select:\{id}" }, @rabbita.none))
      } else {
        match workspace_entry_for(workspace.entries, id) {
          Some(entry) => {
            let next = workspace_apply_entry(
              { ..workspace, loading: true, error: "", notice: "" },
              entry,
            )
            Some(
              (
                next,
                @cmd.batch([
                  select_workspace(emit, id),
                  persist_workspace_binding(id, next.session_id),
                ]),
              ),
            )
          }
          None =>
            Some(
              ({ ..workspace, error: "工作区不存在。" }, @rabbita.none),
            )
        }
      }
    WorkspaceCreateWorktree =>
      if workspace.id == "" || workspace.kind != "local" {
        Some((workspace, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            create_workspace_worktree(emit, workspace.id, workspace.session_id),
          ),
        )
      }
    WorkspacePin =>
      if workspace.id == "" {
        Some((workspace, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            pin_workspace(emit, workspace.id, !workspace.pinned),
          ),
        )
      }
    WorkspaceDelete =>
      if workspace.id == "" || workspace.pinned {
        Some(
          (
            { ..workspace, error: "置顶工作区不能直接删除。" },
            @rabbita.none,
          ),
        )
      } else if workspace_changed(workspace) {
        Some(({ ..workspace, pending_action: "delete" }, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            delete_workspace(emit, workspace.id),
          ),
        )
      }
    WorkspaceHandoff(target_id) =>
      if workspace.id == "" || target_id == "" {
        Some((workspace, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            handoff_workspace(emit, workspace.id, target_id, workspace.revision),
          ),
        )
      }
    WorkspaceDirtySave =>
      if !workspace_changed(workspace) {
        Some(({ ..workspace, pending_action: "" }, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "" },
            save_workspace_file(
              emit,
              workspace.id,
              workspace.selected_path,
              workspace.content,
              workspace.line_endings,
              workspace.file_revision,
            ),
          ),
        )
      }
    WorkspaceDirtyDiscard => {
      let action = workspace.pending_action
      let next = {
        ..workspace,
        content: workspace.saved_content,
        pending_action: "",
      }
      if action == "close" {
        Some(({ ..next, open: false }, after_render_focus(".workspace-toggle")))
      } else if action.has_prefix("select:") {
        match workspace_entry_for(workspace.entries, action[7:].to_owned()) {
          Some(entry) => {
            let selected = workspace_apply_entry(
              { ..next, loading: true },
              entry,
            )
            Some(
              (
                selected,
                @cmd.batch([
                  select_workspace(emit, entry.id),
                  persist_workspace_binding(entry.id, selected.session_id),
                ]),
              ),
            )
          }
          None => Some((next, @rabbita.none))
        }
      } else if action == "delete" {
        Some(({ ..next, loading: true }, delete_workspace(emit, workspace.id)))
      } else {
        Some((next, @rabbita.none))
      }
    }
    WorkspaceDirtyCancel =>
      Some(({ ..workspace, pending_action: "" }, @rabbita.none))
    WorkspacePick =>
      Some(
        (
          { ..workspace, loading: true, error: "", notice: "" },
          pick_workspace(emit),
        ),
      )
    WorkspacePicked(source) =>
      if workspace_pick_cancelled(source) {
        Some(({ ..workspace, loading: false }, @rabbita.none))
      } else {
        match decode_workspace_pick(source) {
          Some((id, name)) => {
            let next = {
              ..workspace,
              id,
              name,
              root: "",
              files: [],
              selected_path: "",
              content: "",
              saved_content: "",
              changes: [],
              branch: "",
              revision: "",
              file_revision: "",
              diff: "",
              loading: true,
              error: "",
              notice: "已选择工作区",
            }
            Some(
              (
                next,
                @cmd.batch([
                  load_workspace_registry(emit),
                  select_workspace(emit, id),
                  persist_workspace_binding(id, workspace.session_id),
                ]),
              ),
            )
          }
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "工作区选择结果无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceTreeReceived(workspace_id, source) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else {
        match decode_workspace_tree(source) {
          Some((root, files)) =>
            Some(
              (
                {
                  ..workspace,
                  root,
                  files,
                  expanded_groups: [""],
                  loading: false,
                  error: "",
                },
                @rabbita.none,
              ),
            )
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "工作区文件列表格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceFilterChanged(filter) =>
      Some(({ ..workspace, filter, }, @rabbita.none))
    WorkspaceToggleGroup(key) =>
      Some(
        (
          {
            ..workspace,
            expanded_groups: toggle_workspace_group(
              workspace.expanded_groups,
              key,
            ),
          },
          @rabbita.none,
        ),
      )
    WorkspaceSelectFile(path) =>
      Some(
        (
          {
            ..workspace,
            selected_path: path,
            loading: true,
            error: "",
            notice: "",
          },
          load_workspace_file(emit, workspace.id, path),
        ),
      )
    WorkspaceFileReceived(workspace_id, path, source) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else {
        match decode_workspace_file(source) {
          Some((content, line_endings)) if path == workspace.selected_path =>
            Some(
              (
                {
                  ..workspace,
                  content,
                  saved_content: content,
                  file_revision: decode_workspace_file_revision(source),
                  line_endings: if line_endings == "crlf" {
                    "crlf"
                  } else {
                    "lf"
                  },
                  loading: false,
                  error: "",
                },
                @rabbita.none,
              ),
            )
          Some(_) => Some((workspace, @rabbita.none))
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "文件响应格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceContentChanged(content) =>
      Some(({ ..workspace, content, notice: "" }, @rabbita.none))
    WorkspaceSaveFile =>
      if workspace.selected_path == "" || !workspace_changed(workspace) {
        Some((workspace, @rabbita.none))
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            save_workspace_file(
              emit,
              workspace.id,
              workspace.selected_path,
              workspace.content,
              workspace.line_endings,
              workspace.file_revision,
            ),
          ),
        )
      }
    WorkspaceFileSaved(workspace_id, path, content) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else if path == workspace.selected_path && content == workspace.content {
        let pending = workspace.pending_action
        let saved = {
          ..workspace,
          saved_content: content,
          loading: false,
          notice: "已保存",
          error: "",
          pending_action: "",
        }
        if pending == "close" {
          Some(
            ({ ..saved, open: false }, after_render_focus(".workspace-toggle")),
          )
        } else if pending == "delete" {
          Some(
            ({ ..saved, loading: true }, delete_workspace(emit, workspace.id)),
          )
        } else if pending.has_prefix("select:") {
          match workspace_entry_for(workspace.entries, pending[7:].to_owned()) {
            Some(entry) => {
              let selected = workspace_apply_entry(
                { ..saved, loading: true },
                entry,
              )
              Some(
                (
                  selected,
                  @cmd.batch([
                    select_workspace(emit, entry.id),
                    persist_workspace_binding(entry.id, selected.session_id),
                  ]),
                ),
              )
            }
            None => Some((saved, @rabbita.none))
          }
        } else {
          Some(
            (
              saved,
              @cmd.batch([
                load_workspace_file(emit, workspace.id, path),
                load_workspace_status(emit, workspace.id),
              ]),
            ),
          )
        }
      } else {
        Some((workspace, load_workspace_status(emit, workspace.id)))
      }
    WorkspaceStatusReceived(workspace_id, source) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else {
        match apply_workspace_status(workspace, source) {
          Some(next) => Some((next, @rabbita.none))
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "Git 状态响应格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceDiffScopeChanged(scope) =>
      Some(
        (
          { ..workspace, diff_scope: scope, loading: true, error: "" },
          load_workspace_diff(emit, workspace.id, scope, ""),
        ),
      )
    WorkspaceDiffReceived(workspace_id, scope, _, source) =>
      if workspace_id != workspace.id || scope != workspace.diff_scope {
        Some((workspace, @rabbita.none))
      } else {
        match decode_workspace_diff(source) {
          Some(diff) =>
            Some(
              ({ ..workspace, diff, loading: false, error: "" }, @rabbita.none),
            )
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "Diff 响应格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceRefresh =>
      Some(
        (
          { ..workspace, loading: true, error: "", notice: "" },
          @cmd.batch([
            load_workspace_tree(emit, workspace.id),
            load_workspace_status(emit, workspace.id),
            if workspace.tab == "diff" {
              load_workspace_diff(emit, workspace.id, workspace.diff_scope, "")
            } else {
              @rabbita.none
            },
          ]),
        ),
      )
    WorkspaceStage(path) =>
      Some(
        (
          { ..workspace, loading: true, error: "", notice: "" },
          workspace_git_paths_request(emit, workspace.id, "stage", [path]),
        ),
      )
    WorkspaceUnstage(path) =>
      Some(
        (
          { ..workspace, loading: true, error: "", notice: "" },
          workspace_git_paths_request(emit, workspace.id, "unstage", [path]),
        ),
      )
    WorkspaceGitActionReceived(workspace_id, action, source) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else {
        match apply_workspace_status(workspace, source) {
          Some(next) =>
            Some(
              (
                {
                  ..next,
                  notice: if action == "stage" {
                    "已暂存"
                  } else {
                    "已取消暂存"
                  },
                },
                if workspace.tab == "diff" {
                  load_workspace_diff(
                    emit,
                    workspace.id,
                    workspace.diff_scope,
                    "",
                  )
                } else {
                  @rabbita.none
                },
              ),
            )
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "Git 操作响应格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceCommitMessageChanged(message) =>
      Some(
        ({ ..workspace, commit_message: message, notice: "" }, @rabbita.none),
      )
    WorkspaceCommit =>
      if workspace.commit_message.trim().is_empty() {
        Some(
          ({ ..workspace, error: "请输入提交说明。" }, @rabbita.none),
        )
      } else {
        Some(
          (
            { ..workspace, loading: true, error: "", notice: "" },
            commit_workspace_changes(
              emit,
              workspace.id,
              workspace.commit_message,
            ),
          ),
        )
      }
    WorkspaceCommitReceived(workspace_id, source) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else {
        match apply_workspace_status(workspace, source) {
          Some(next) =>
            Some(
              (
                { ..next, commit_message: "", notice: "提交已创建" },
                @rabbita.none,
              ),
            )
          None =>
            Some(
              (
                {
                  ..workspace,
                  loading: false,
                  error: "提交响应格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      }
    WorkspaceFailed(reason) =>
      Some(
        (
          { ..workspace, loading: false, error: reason, notice: "" },
          @rabbita.none,
        ),
      )
    _ => None
  }
}
