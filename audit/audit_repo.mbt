///|
// 校验 GitHub 组件(owner/repo):仅允许 [A-Za-z0-9._-],长度 1..100,
// 拒绝 "." 与 "..",防止异常组件进入克隆 URL。
fn valid_repo_component(s : String) -> Bool {
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
// 从 GitHub repository URL 解析出 (owner, repo)。
fn parse_github_repo(url : String) -> (String, String)? {
  let u = url.trim()
  let prefix = "https://github.com/"
  guard u.has_prefix(prefix) else { return None }
  let rest = u[prefix.length():].to_owned()
  let parts = rest.split("/").to_array()
  // Mooncakes metadata is an input boundary. Accept only a canonical public
  // GitHub repository URL, never a tree/blob URL, query, fragment, or redirect
  // shaped path.
  guard parts.length() == 2 else { return None }
  let owner = parts[0].to_owned()
  let mut repo = parts[1].to_owned()
  if repo.has_suffix(".git") {
    repo = repo[:repo.length() - 4].to_owned()
  }
  if valid_repo_component(owner) && valid_repo_component(repo) {
    Some((owner, repo))
  } else {
    None
  }
}

///|
#cfg(platform="windows")
fn audit_git_null_device() -> String {
  "NUL"
}

///|
#cfg(not(platform="windows"))
fn audit_git_null_device() -> String {
  "/dev/null"
}

///|
fn audit_repo_environment() -> Map[String, String] {
  let environment : Map[String, String] = {
    "GIT_CONFIG_GLOBAL": audit_git_null_device(),
    "GIT_LFS_SKIP_SMUDGE": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GCM_INTERACTIVE": "Never",
  }
  // Keep only process-launch and temporary-directory state. In particular,
  // never expose model keys, GitHub tokens, SSH agents, or credential sockets
  // to an untrusted repository operation.
  for
    name in [
      "PATH", "SystemRoot", "ComSpec", "PATHEXT", "TEMP", "TMP", "TMPDIR",
    ] {
    match @sys.get_env_var(name) {
      Some(value) if value != "" => environment[name] = value
      _ => ()
    }
  }
  environment
}

///|
fn secured_clone_args(
  url : String,
  target : String,
  branch? : String = "",
) -> Array[String] {
  let hooks = audit_git_null_device()
  let args = [
    "-c",
    "core.hooksPath=\{hooks}",
    "-c",
    "credential.helper=",
    "-c",
    "submodule.recurse=false",
    "clone",
    "--no-recurse-submodules",
    "--no-tags",
    "--config",
    "core.hooksPath=\{hooks}",
    "--config",
    "credential.helper=",
    "--config",
    "submodule.recurse=false",
  ]
  if branch != "" {
    args.push("--depth")
    args.push("1")
    args.push("--single-branch")
    args.push("--branch")
    args.push(branch)
  }
  args.push(url)
  args.push(target)
  args
}

///|
fn clip_audit_repo_output(text : String) -> String {
  if text.length() <= 8192 {
    text
  } else {
    text[:8192].to_owned() + "\n... (output truncated)"
  }
}

///|
async fn run_audit_git(args : Array[String], timeout_ms : Int) -> (Int, String) {
  let result = @async.with_timeout_opt(timeout_ms, async fn() {
    let (exit, _, err) = @process.collect_output(
      "git",
      args,
      extra_env=audit_repo_environment(),
      inherit_env=false,
      no_console_window=true,
    )
    (exit, clip_audit_repo_output(err.text() catch { _ => "" }))
  })
  match result {
    Some(value) => value
    None =>
      (-1, "git command timed out after \{timeout_ms} ms and was terminated")
  }
}

///|
fn audit_json_string(value : Json, key : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
// 从 manifest JSON 提取 GitHub repository URL。
fn manifest_repository(manifest : String) -> String raise {
  let document = @json.parse(manifest)
  guard document is Object(fields) else { fail("invalid manifest JSON") }
  match fields.get("metadata") {
    Some(Object(meta)) => {
      let repo = audit_json_string(Json::object(meta), "repository")
      guard repo != "" else { fail("manifest has no repository URL") }
      repo
    }
    _ => fail("manifest has no metadata")
  }
}

///|
async fn has_file(dir : String, name : String) -> Bool {
  let kind = @fs.kind(dir + "/" + name) catch { _ => @fs.FileKind::Unknown }
  kind is @fs.FileKind::Regular
}

///|
async fn is_moon_project(dir : String) -> Bool {
  has_file(dir, "moon.mod") || has_file(dir, "moon.mod.json")
}

///|
// 在解压目录中定位含 moon.mod 的项目根（tarball 顶层多包了一层目录，
// 某些仓库使用 moon.work 多模块结构，需要再往下一层找）。
async fn locate_project_root(dest_dir : String) -> String {
  if is_moon_project(dest_dir) {
    return dest_dir
  }
  let entries = @fs.readdir(dest_dir, sort=true)
  for entry in entries {
    let path = dest_dir + "/" + entry
    if @fs.kind(path) is @fs.FileKind::Directory {
      if is_moon_project(path) {
        return path
      }
      let subs = @fs.readdir(path, sort=true)
      for sub in subs {
        let subpath = path + "/" + sub
        if is_moon_project(subpath) {
          return subpath
        }
      }
    }
  }
  fail("no moon.mod found in downloaded source")
}

///|
// 用浅克隆拉取源码到 dest_dir，返回项目根目录。
// 相比下载 tarball，git clone 自带 .git，后续 `git diff` 可直接呈现修复改动。
async fn fetch_repo_source(
  owner : String,
  repo : String,
  dest_dir : String,
  full? : Bool = false,
) -> String {
  let url = "https://github.com/\{owner}/\{repo}.git"
  let target = dest_dir + "/repo"
  let target_kind = @fs.kind(target) catch { _ => @fs.FileKind::Unknown }
  if target_kind is @fs.FileKind::Directory {
    fail("target directory already exists, refusing to delete it: \{target}")
  }
  // 普通审计先试 main，再试 master；所有分支共享同一个网络重试预算。
  // full clone 不需要猜默认分支，因此只执行一次分支无关的 clone。
  let mut last_err = "git clone failed"
  let branches = if full { [""] } else { ["main", "master"] }
  let mut attempts = 0
  for branch in branches {
    for ;; {
      guard attempts < 4 else { break }
      attempts += 1
      let clone_args = if full {
        secured_clone_args(url, target)
      } else {
        secured_clone_args(url, target, branch~)
      }
      let (exit, err) = run_audit_git(clone_args, 300_000)
      if exit == 0 {
        return locate_project_root(dest_dir)
      }
      last_err = err
      remove_workspace_dir(target)
    }
  }
  fail(last_err)
}

///|
// 定位系统临时目录根：与 async/fs 内部实现一致，依次使用
// TEMP / TMP / TMPDIR，最后回退到 Windows 用户临时目录或 /tmp。
fn audit_temp_root() -> String {
  match @sys.get_env_var("TEMP") {
    Some(path) => path
    None =>
      match @sys.get_env_var("TMP") {
        Some(path) => path
        None =>
          match @sys.get_env_var("TMPDIR") {
            Some(path) => path
            None =>
              match @sys.get_env_var("USERPROFILE") {
                Some(home) => home + "/AppData/Local/Temp"
                None => "/tmp"
              }
          }
      }
  }
}

///|
// 删除临时目录下所有 moonsage-audit-* 目录，返回删除数量。
async fn clean_audit_temp_dirs() -> Int {
  let root = audit_temp_root().trim_end(chars="\\/").to_owned()
  let entries = @fs.readdir(root, sort=true) catch { _ => return 0 }
  let mut removed = 0
  for entry in entries {
    if entry.has_prefix("moonsage-audit-") {
      let path = root + "/" + entry
      if @fs.kind(path) is @fs.FileKind::Directory {
        remove_workspace_dir(path)
        let still = @fs.kind(path) catch { _ => @fs.FileKind::Unknown }
        if !(still is @fs.FileKind::Directory) {
          removed += 1
        }
      }
    }
  }
  removed
}

///|
// 递归删除审计工作区目录。git clone 会在 .git/objects/pack 下生成只读文件，
// Windows 上 @fs.rmdir 无法删除它们（@fs.chmod 在 Windows 也不受支持），
// 因此改用平台原生的强制删除命令：PowerShell 会先清除只读属性。
#cfg(platform="windows")
async fn remove_workspace_dir(path : String) -> Unit {
  // Windows 文件名不可能包含 `"`，因此可以安全地内嵌到命令字符串中。
  let cmd = "Remove-Item -LiteralPath \"" + path + "\" -Recurse -Force"
  ignore(
    @process.collect_output(
      "powershell",
      ["-NoProfile", "-NonInteractive", "-Command", cmd],
      no_console_window=true,
    ),
  )
}

///|
#cfg(not(platform="windows"))
async fn remove_workspace_dir(path : String) -> Unit {
  ignore(
    @process.collect_output("rm", ["-rf", "--", path], no_console_window=true),
  )
}
