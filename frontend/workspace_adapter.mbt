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
fn load_workspace_tree(emit : Emit[Msg]) -> Cmd {
  workspace_request(emit, "GET", "/api/workspace/tree", "", body => {
    WorkspaceTreeReceived(body)
  })
}

///|
fn load_workspace_status(emit : Emit[Msg]) -> Cmd {
  workspace_request(emit, "GET", "/api/workspace/git/status", "", body => {
    WorkspaceStatusReceived(body)
  })
}

///|
fn load_workspace_file(emit : Emit[Msg], path : String) -> Cmd {
  workspace_request(
    emit,
    "GET",
    "/api/workspace/file?path=" + encode_workspace_path(path),
    "",
    body => WorkspaceFileReceived(path, body),
  )
}

///|
fn save_workspace_file(
  emit : Emit[Msg],
  path : String,
  content : String,
  line_endings : String,
) -> Cmd {
  let body = Json::object({
    "path": Json::string(path),
    "content": Json::string(content),
    "line_endings": Json::string(line_endings),
  }).stringify()
  workspace_request(emit, "PUT", "/api/workspace/file", body, _ => {
    WorkspaceFileSaved(path, content)
  })
}

///|
fn load_workspace_diff(emit : Emit[Msg], scope : String, path : String) -> Cmd {
  let suffix = if path == "" {
    ""
  } else {
    "&path=" + encode_workspace_path(path)
  }
  let url = "/api/workspace/git/diff?scope=" + scope + suffix
  workspace_request(emit, "GET", url, "", body => {
    WorkspaceDiffReceived(scope, path, body)
  })
}

///|
fn workspace_git_paths_request(
  emit : Emit[Msg],
  action : String,
  paths : Array[String],
) -> Cmd {
  let body = Json::object({ "paths": Json::array(paths.map(Json::string)) }).stringify()
  workspace_request(emit, "POST", "/api/workspace/git/" + action, body, result => {
    WorkspaceGitActionReceived(action, result)
  })
}

///|
fn commit_workspace_changes(emit : Emit[Msg], message : String) -> Cmd {
  let body = Json::object({ "message": Json::string(message) }).stringify()
  workspace_request(emit, "POST", "/api/workspace/git/commit", body, result => {
    WorkspaceCommitReceived(result)
  })
}
