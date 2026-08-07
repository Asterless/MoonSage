///|
// 网络请求超时：mooncakes API / 静态资源 30 秒无响应即失败，避免交互
// 界面在连接或读取阶段无限期挂起。
let http_timeout_ms = 30000

///|
pub async fn fetch_modules() -> Array[@moonsage.ModuleSummary] {
  let (response, body) = @async.with_timeout(http_timeout_ms, () => {
    @http.get("https://mooncakes.io/api/v0/modules")
  }) catch {
    @async.TimeoutError(_) =>
      fail("Mooncakes API timed out (\{http_timeout_ms} ms)")
    err => raise err
  }
  guard response.code == 200 else {
    fail("Mooncakes API returned HTTP \{response.code}")
  }
  @moonsage.parse_modules(body.text())
}

///|
pub async fn fetch_manifest(arguments : String) -> String {
  let name = @tools.argument_string(arguments, "name")
  guard valid_module_name(name) else { fail("invalid Mooncakes module name") }
  fetch_asset(
    "https://mooncakes.io/api/v0/manifest/\{name}",
    "Mooncakes manifest API",
  )
}

///|
pub async fn fetch_module_index(arguments : String) -> String {
  let name = @tools.argument_string(arguments, "name")
  let version = @tools.argument_string(arguments, "version")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/module_index.json"
  @moonsage.compact_module_index(fetch_asset(url, "Mooncakes module index"))
}

///|
pub async fn fetch_package_docs(arguments : String) -> String {
  let name = @tools.argument_string(arguments, "name")
  let version = @tools.argument_string(arguments, "version")
  let path = @tools.argument_string(arguments, "package_path")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let relpath = package_relpath(name, path)
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/\{relpath}/package_data.json"
  @moonsage.compact_package_docs(fetch_asset(url, "Mooncakes package docs"))
}

///|
pub async fn fetch_asset(url : String, error_label : String) -> String {
  let (response, body) = @async.with_timeout(http_timeout_ms, () => {
    @http.get(url, headers=asset_headers())
  }) catch {
    @async.TimeoutError(_) =>
      fail("\{error_label} timed out (\{http_timeout_ms} ms)")
    err => raise err
  }
  let text = body.text()
  guard response.code == 200 else {
    fail("\{error_label} returned HTTP \{response.code}")
  }
  text
}

///|
fn asset_headers() -> Map[String, String] {
  {
    "Accept": "application/json",
    "User-Agent": "MoonSage/0.1 (+https://mooncakes.io)",
  }
}

///|
pub fn valid_module_name(name : String) -> Bool {
  name.contains("/") &&
  !name.contains("..") &&
  !name.contains("?") &&
  !name.contains("#") &&
  !name.contains("\\")
}

///|
pub fn valid_asset_value(value : String) -> Bool {
  value != "" &&
  !value.contains("..") &&
  !value.contains("?") &&
  !value.contains("#") &&
  !value.contains("\\")
}

///|
pub fn package_relpath(name : String, path : String) -> String raise {
  guard valid_asset_value(path) else { fail("invalid Mooncakes package path") }
  let prefix = name + "/"
  if path.has_prefix(prefix) {
    path[prefix.length():].to_owned()
  } else if path == name {
    match name.split_once("/") {
      Some((_, module_path)) => module_path.to_owned()
      None => fail("invalid Mooncakes module name")
    }
  } else {
    path
  }
}

///|
