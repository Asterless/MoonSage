///|
// 从 GitHub URL 解析 (owner, repo)。

///|
// 校验 GitHub 组件(owner/repo)或克隆目标目录名:仅允许 [A-Za-z0-9._-],
// 长度 1..100,并拒绝 "." 与 "..",防止路径逃逸。
fn valid_component(s : String) -> Bool {
  if s.length() < 1 || s.length() > 100 {
    return false
  }
  if s == "." || s == ".." {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let code = s[i].to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !ok {
      return false
    }
  }
  true
}

///|
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
  if valid_component(owner) && valid_component(repo) {
    Some((owner, repo))
  } else {
    None
  }
}

///|
// 解析克隆目标目录名:GitHub URL 用 repo 组件,其他 URL 用最后一段路径;
// 全部经过组件白名单校验,非法时 fail。
fn resolve_clone_target_name(url : String, repo : String) -> String raise {
  if url != "" {
    if url.trim().has_prefix("https://github.com/") {
      match parse_github_url(url) {
        Some((_, r)) => r
        None => fail("invalid GitHub URL: \{url}")
      }
    } else {
      let name = @util.basename(url.trim_end(chars="/").to_owned())
      guard valid_component(name) else {
        fail("invalid clone target name derived from URL: \{url}")
      }
      name
    }
  } else {
    guard valid_component(repo) else {
      fail("invalid repository name: \{repo}")
    }
    repo
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
  let url = @util.json_string_arg(document, "url")
  let owner = @util.json_string_arg(document, "owner")
  let repo = @util.json_string_arg(document, "repo")
  let target_name = resolve_clone_target_name(url, repo)
  let (owner, repo, url) = if url != "" {
    if url.trim().has_prefix("https://github.com/") {
      match parse_github_url(url) {
        Some((o, r)) => (Some(o), Some(r), url)
        None => fail("invalid GitHub URL: \{url}")
      }
    } else {
      (None, None, url)
    }
  } else {
    guard owner != "" && repo != "" else {
      fail("clone_repo requires url, or owner + repo")
    }
    guard valid_component(owner) && valid_component(repo) else {
      fail("invalid owner/repo: \{owner}/\{repo}")
    }
    (Some(owner), Some(repo), "https://github.com/\{owner}/\{repo}.git")
  }
  let base = ws.clone_base()
  @fs.mkdir(base, recursive=true) catch {
    _ => ()
  }
  let target = base + "/" + target_name
  guard target.has_prefix(base + "/") else {
    fail("clone target escapes the workspace base")
  }
  let already_cloned = dir_exists(target)
  if already_cloned {
    // 复用已有克隆（会话恢复后重新 clone 也安全）。
    let (probe_exit, probe_err) = run_cmd_with_timeout(
      ["rev-parse", "--git-dir"],
      10_000,
      cwd=target,
    )
    guard probe_exit == 0 else {
      fail(
        "clone target \{target} already exists but is not a git repository: \{probe_err}",
      )
    }
  } else {
    let (exit, err) = run_cmd_with_timeout(
      ["clone", "--depth", "1", url, target],
      300_000,
    )
    guard exit == 0 else { fail("clone failed: \{err}") }
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
  let title = @util.json_string_arg(document, "title")
  let body = @util.json_string_arg(document, "body")
  let branch = @util.json_string_arg(document, "branch")
  let (owner, repo) = current_repo_owner_name(ws.get_root())
  let report = if body != "" { body } else { "Automated changes by MoonSage." }
  match
    publish_changes(ws.get_root(), owner, repo, Prompt, report, title~, branch~) {
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
        description: "Commit the current changes in the workspace, push a branch (forking first when needed) and open a pull request against the repository's origin. Asks for confirmation before pushing. Provide optional title, body and branch (branch defaults to moonsage/fix-<repo>, auto-suffixed when taken).",
        parameters: @tools.object_schema(
          {
            "title": @tools.string_field("Optional PR title"),
            "body": @tools.string_field("Optional PR body (Markdown)"),
            "branch": @tools.string_field(
              "Optional branch name to push; use a fresh name if the default one already exists on the remote",
            ),
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
