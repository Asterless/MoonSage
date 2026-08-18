///|
extern "js" fn encode_workspace_path(path : String) -> String =
  #| encodeURIComponent

///|
extern "js" fn workspace_http_request(
  verb : String,
  url : String,
  body : String,
  completed : (String) -> Unit,
  failed : (String) -> Unit,
) -> Unit =
  #| (method, url, body, completed, failed) => {
  #|   void (async () => {
  #|     try {
  #|       const response = await fetch(url, {
  #|         method,
  #|         headers: body ? { "Content-Type": "application/json" } : undefined,
  #|         body: body || undefined,
  #|       });
  #|       const text = await response.text();
  #|       let document;
  #|       try { document = JSON.parse(text); }
  #|       catch { throw new Error(text || `HTTP ${response.status}`); }
  #|       if (!response.ok) throw new Error(document.error || `HTTP ${response.status}`);
  #|       completed(text);
  #|     } catch (error) {
  #|       failed(error instanceof Error ? error.message : String(error));
  #|     }
  #|   })();
  #| }

///|
fn workspace_request(
  emit : Emit[Msg],
  verb : String,
  url : String,
  body : String,
  completed : (String) -> Msg,
) -> Cmd {
  @cmd.custom_cmd(scheduler => {
    workspace_http_request(
      verb,
      url,
      body,
      result => scheduler.add(emit(completed(result))),
      reason => scheduler.add(emit(WorkspaceFailed(reason))),
    )
  })
}

///|
fn workspace_prefix(workspace_id : String) -> String {
  if workspace_id == "" {
    "/api/workspace"
  } else {
    "/api/workspaces/" + encode_workspace_path(workspace_id)
  }
}

///|
fn load_workspace_tree(emit : Emit[Msg], workspace_id : String) -> Cmd {
  workspace_request(emit, "GET", workspace_prefix(workspace_id) + "/tree", "", body => {
    WorkspaceTreeReceived(workspace_id, body)
  })
}

///|
fn load_workspace_registry(emit : Emit[Msg]) -> Cmd {
  workspace_request(emit, "GET", "/api/workspaces", "", body => {
    WorkspaceRegistryReceived(body)
  })
}

///|
fn select_workspace(emit : Emit[Msg], workspace_id : String) -> Cmd {
  @cmd.batch([
    load_workspace_tree(emit, workspace_id),
    load_workspace_status(emit, workspace_id),
  ])
}

///|
fn create_workspace_worktree(
  emit : Emit[Msg],
  workspace_id : String,
  session_id : String,
) -> Cmd {
  let body = Json::object({
    "lifecycle": Json::string("temporary"),
    "session_id": Json::string(session_id),
  }).stringify()
  workspace_request(
    emit,
    "POST",
    "/api/workspaces/" + encode_workspace_path(workspace_id) + "/worktree",
    body,
    _ => WorkspaceRegistryReload,
  )
}

///|
fn pin_workspace(emit : Emit[Msg], workspace_id : String, pinned : Bool) -> Cmd {
  let body = Json::object({ "pinned": Json::boolean(pinned) }).stringify()
  workspace_request(
    emit,
    "POST",
    "/api/workspaces/" + encode_workspace_path(workspace_id) + "/pin",
    body,
    _ => WorkspaceRegistryReload,
  )
}

///|
fn delete_workspace(emit : Emit[Msg], workspace_id : String) -> Cmd {
  workspace_request(
    emit,
    "DELETE",
    "/api/workspaces/" + encode_workspace_path(workspace_id),
    "",
    _ => WorkspaceRegistryReload,
  )
}

///|
fn handoff_workspace(
  emit : Emit[Msg],
  source_id : String,
  target_id : String,
  expected_revision : String,
) -> Cmd {
  let body = Json::object({
    "target_workspace_id": Json::string(target_id),
    "expected_revision": Json::string(expected_revision),
  }).stringify()
  workspace_request(
    emit,
    "POST",
    "/api/workspaces/" + encode_workspace_path(source_id) + "/handoff",
    body,
    _ => WorkspaceRegistryReload,
  )
}

///|
fn pick_workspace(emit : Emit[Msg]) -> Cmd {
  workspace_request(emit, "POST", "/api/workspaces/pick", "", body => {
    WorkspacePicked(body)
  })
}

///|
fn load_workspace_status(emit : Emit[Msg], workspace_id : String) -> Cmd {
  workspace_request(
    emit,
    "GET",
    workspace_prefix(workspace_id) + "/git/status",
    "",
    body => WorkspaceStatusReceived(workspace_id, body),
  )
}

///|
fn load_workspace_file(
  emit : Emit[Msg],
  workspace_id : String,
  path : String,
) -> Cmd {
  workspace_request(
    emit,
    "GET",
    workspace_prefix(workspace_id) + "/file?path=" + encode_workspace_path(path),
    "",
    body => WorkspaceFileReceived(workspace_id, path, body),
  )
}

///|
fn save_workspace_file(
  emit : Emit[Msg],
  workspace_id : String,
  path : String,
  content : String,
  line_endings : String,
  expected_revision : String,
) -> Cmd {
  let fields : Map[String, Json] = {
    "path": Json::string(path),
    "content": Json::string(content),
    "line_endings": Json::string(line_endings),
  }
  if expected_revision != "" {
    fields["expected_revision"] = Json::string(expected_revision)
  }
  let body = Json::object(fields).stringify()
  workspace_request(
    emit,
    "PUT",
    workspace_prefix(workspace_id) + "/file",
    body,
    _ => WorkspaceFileSaved(workspace_id, path, content),
  )
}

///|
fn load_workspace_diff(
  emit : Emit[Msg],
  workspace_id : String,
  scope : String,
  path : String,
) -> Cmd {
  let suffix = if path == "" {
    ""
  } else {
    "&path=" + encode_workspace_path(path)
  }
  let url = workspace_prefix(workspace_id) + "/git/diff?scope=" + scope + suffix
  workspace_request(emit, "GET", url, "", body => {
    WorkspaceDiffReceived(workspace_id, scope, path, body)
  })
}

///|
fn workspace_git_paths_request(
  emit : Emit[Msg],
  workspace_id : String,
  action : String,
  paths : Array[String],
) -> Cmd {
  let body = Json::object({ "paths": Json::array(paths.map(Json::string)) }).stringify()
  workspace_request(
    emit,
    "POST",
    workspace_prefix(workspace_id) + "/git/" + action,
    body,
    result => WorkspaceGitActionReceived(workspace_id, action, result),
  )
}

///|
fn commit_workspace_changes(
  emit : Emit[Msg],
  workspace_id : String,
  message : String,
) -> Cmd {
  let body = Json::object({ "message": Json::string(message) }).stringify()
  workspace_request(
    emit,
    "POST",
    workspace_prefix(workspace_id) + "/git/commit",
    body,
    result => WorkspaceCommitReceived(workspace_id, result),
  )
}
