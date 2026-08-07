///|
// 从 GitHub URL 解析 (owner, repo)。
pub fn parse_github_url(url : String) -> (String, String)? {
  let u = url.trim()
  let prefix = "https://github.com/"
  guard u.has_prefix(prefix) else { return None }
  let rest = u[prefix.length():].to_owned()
  let parts = rest.split("/").to_array()
  guard parts.length() >= 2 else { return None }
  let owner = parts[0].to_owned()
  let mut repo = parts[1].trim_end(chars="/").to_owned()
  if repo.has_suffix(".git") {
    repo = repo[:repo.length() - 4].to_owned()
  }
  if owner != "" && repo != "" {
    Some((owner, repo))
  } else {
    None
  }
}

///|
// 从工作区 git origin 解析 (owner, repo)。
async fn current_repo_owner_name(root : String) -> (String, String) {
  let (exit, out, _) = @process.collect_output(
    "git",
    ["config", "--get", "remote.origin.url"],
    cwd=root,
    no_console_window=true,
  )
  guard exit == 0 else {
    fail("workspace is not a git repository with an origin remote")
  }
  let url = (out.text() catch { _ => "" }).trim().to_owned()
  match parse_github_url(url) {
    Some(pair) => pair
    None => fail("origin is not a GitHub URL: \{url}")
  }
}

///|
async fn clone_repo_tool(ws : Workspace, arguments : String) -> String {
  let document = @json.parse(arguments)
  let url = json_string_arg(document, "url")
  let owner = json_string_arg(document, "owner")
  let repo = json_string_arg(document, "repo")
  let (owner, repo, url, target_name) = if url != "" {
    match parse_github_url(url) {
      Some((o, r)) => (Some(o), Some(r), url, r)
      None => (None, None, url, basename(url.trim_end(chars="/").to_owned()))
    }
  } else {
    guard owner != "" && repo != "" else {
      fail("clone_repo requires url, or owner + repo")
    }
    (Some(owner), Some(repo), "https://github.com/\{owner}/\{repo}.git", repo)
  }
  let base = ws.clone_base()
  @fs.mkdir(base, recursive=true) catch {
    _ => ()
  }
  let target = base + "/" + target_name
  let already_cloned = dir_exists(target)
  if already_cloned {
    // 复用已有克隆（会话恢复后重新 clone 也安全）。
    let (probe_exit, _, probe_err) = @process.collect_output(
      "git",
      ["rev-parse", "--git-dir"],
      cwd=target,
      no_console_window=true,
    )
    guard probe_exit == 0 else {
      fail(
        "clone target \{target} already exists but is not a git repository: \{probe_err.text()}",
      )
    }
  } else {
    let (exit, _, err) = @process.collect_output(
      "git",
      ["clone", "--depth", "1", url, target],
      no_console_window=true,
    )
    guard exit == 0 else { fail("clone failed: \{err.text()}") }
  }
  ws.set_root(target)
  let reused = if already_cloned { " (reused existing clone)" } else { "" }
  match (owner, repo) {
    (Some(o), Some(r)) => "cloned \{o}/\{r} to \{target}\{reused}"
    _ => "cloned \{url} to \{target}\{reused}"
  }
}

///|
async fn create_pr_tool(ws : Workspace, arguments : String) -> String {
  let document = @json.parse(arguments)
  let title = json_string_arg(document, "title")
  let body = json_string_arg(document, "body")
  let (owner, repo) = current_repo_owner_name(ws.get_root())
  let report = if body != "" { body } else { "Automated changes by MoonSage." }
  match publish_changes(ws.get_root(), owner, repo, Prompt, report, title~) {
    Some(url) => "PR created: \{url}"
    None => "PR cancelled by user"
  }
}

///|
// 仓库操作工具集：clone_repo（克隆并切换工作区根目录）与 create_pr（发布 PR）。
pub fn publish_tools(ws : Workspace) -> Array[@tools.Tool] {
  [
    {
      schema: {
        name: "clone_repo",
        description: "Clone a GitHub repository into the workspace (under .moonsage/workspaces) and switch all file tools to the clone. Provide url, or owner + repo.",
        parameters: @tools.object_schema(
          {
            "url": @tools.string_field(
              "Optional full GitHub URL, e.g. https://github.com/owner/repo",
            ),
            "owner": @tools.string_field("Optional repository owner"),
            "repo": @tools.string_field("Optional repository name"),
          },
          [],
        ),
      },
      execute: async fn(arguments) {
        clone_repo_tool(ws, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "create_pr",
        description: "Commit the current changes in the workspace, push a branch (forking first when needed) and open a pull request against the repository's origin. Asks for confirmation before pushing. Provide optional title and body.",
        parameters: @tools.object_schema(
          {
            "title": @tools.string_field("Optional PR title"),
            "body": @tools.string_field("Optional PR body (Markdown)"),
          },
          [],
        ),
      },
      execute: async fn(arguments) {
        create_pr_tool(ws, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
  ]
}
