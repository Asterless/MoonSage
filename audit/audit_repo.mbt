///|
// 从 GitHub repository URL 解析出 (owner, repo)。
fn parse_github_repo(url : String) -> (String, String)? {
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
) -> String {
  let url = "https://github.com/\{owner}/\{repo}.git"
  let target = dest_dir + "/repo"
  let target_kind = @fs.kind(target) catch { _ => @fs.FileKind::Unknown }
  if target_kind is @fs.FileKind::Directory {
    fail("target directory already exists, refusing to delete it: \{target}")
  }
  // 先试 main，再试 master；网络波动时对同一分支重试几次。
  let mut last_err = "git clone failed"
  for branch in ["main", "master"] {
    for retry = 0; retry < 3; retry = retry + 1 {
      let (exit, _, err) = @process.collect_output(
        "git",
        [
          "clone", "--depth", "1", "--single-branch", "--branch", branch, url, target,
        ],
        no_console_window=true,
      )
      if exit == 0 {
        return locate_project_root(dest_dir)
      }
      last_err = err.text()
      @fs.rmdir(target, recursive=true) catch {
        _ => ()
      }
    }
  }
  fail(last_err)
}

///|
async fn git_diff(project_dir : String, path : String?) -> String {
  let args = if path is Some(p) { ["diff", "--", p] } else { ["diff"] }
  let (exit, out, _) = @process.collect_output(
    "git",
    args,
    cwd=project_dir,
    no_console_window=true,
  )
  if exit != 0 {
    "(git diff failed)"
  } else {
    out.text() catch {
      _ => ""
    }
  }
}
