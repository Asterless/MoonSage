///|
struct WorkspaceChange {
  path : String
  index : String
  worktree : String
  staged : Bool
  unstaged : Bool
  untracked : Bool
} derive(Eq)

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
  id : String
  name : String
  tab : String
  root : String
  files : Array[String]
  filter : String
  expanded_groups : Array[String]
  selected_path : String
  content : String
  saved_content : String
  line_endings : String
  branch : String
  changes : Array[WorkspaceChange]
  diff_scope : String
  diff : String
  commit_message : String
  loading : Bool
  notice : String
  error : String
} derive(Eq)

///|
fn initial_workspace() -> WorkspaceModel {
  {
    open: false,
    id: "",
    name: "",
    tab: "files",
    root: "",
    files: [],
    filter: "",
    expanded_groups: [""],
    selected_path: "",
    content: "",
    saved_content: "",
    line_endings: "lf",
    branch: "",
    changes: [],
    diff_scope: "working",
    diff: "",
    commit_message: "",
    loading: false,
    notice: "",
    error: "",
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
  guard json_fields(source) is Some(fields) else { return None }
  guard fields.get("workspaces") is Some(Array(items)) else { return None }
  for item in items {
    guard item is Object(workspace) else { continue }
    match workspace.get("id") {
      Some(String(id)) =>
        return Some((id, json_string_field(workspace, "name")))
      _ => continue
    }
  }
  Some(("", ""))
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
      index: json_string_field(fields, "index"),
      worktree: json_string_field(fields, "worktree"),
      staged: boolean("staged"),
      unstaged: boolean("unstaged"),
      untracked: boolean("untracked"),
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
fn workspace_view(
  workspace : WorkspaceModel,
  modal : Bool,
  emit : Emit[Msg],
) -> Html {
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
        Some(
          (
            { ..workspace, open: false, loading: false },
            after_render_focus(".workspace-toggle"),
          ),
        )
      } else {
        let next = { ..workspace, open: true, loading: true, error: "" }
        Some(
          (
            next,
            @cmd.batch([
              load_workspace_registry(emit),
              load_workspace_tree(emit, workspace.id),
              load_workspace_status(emit, workspace.id),
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
    WorkspaceRegistryReceived(source) =>
      match decode_workspace_registry(source) {
        Some((id, name)) => {
          if workspace.id != "" {
            return Some((workspace, @rabbita.none))
          }
          let next = { ..workspace, id, name, error: "" }
          Some(
            (
              next,
              @cmd.batch([
                load_workspace_tree(emit, next.id),
                load_workspace_status(emit, next.id),
              ]),
            ),
          )
        }
        None =>
          Some(
            (
              { ..workspace, error: "工作区注册信息格式无效。" },
              @rabbita.none,
            ),
          )
      }
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
              diff: "",
              loading: true,
              error: "",
              notice: "已选择工作区",
            }
            Some(
              (
                next,
                @cmd.batch([
                  load_workspace_tree(emit, id),
                  load_workspace_status(emit, id),
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
            ),
          ),
        )
      }
    WorkspaceFileSaved(workspace_id, path, content) =>
      if workspace_id != workspace.id {
        Some((workspace, @rabbita.none))
      } else if path == workspace.selected_path && content == workspace.content {
        Some(
          (
            {
              ..workspace,
              saved_content: content,
              loading: false,
              notice: "已保存",
              error: "",
            },
            load_workspace_status(emit, workspace.id),
          ),
        )
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
