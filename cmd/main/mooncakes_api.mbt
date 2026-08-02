///|
async fn fetch_modules() -> Array[@moonsage.ModuleSummary] {
  let (response, body) = @http.get("https://mooncakes.io/api/v0/modules")
  guard response.code == 200 else {
    fail("Mooncakes API returned HTTP \{response.code}")
  }
  @moonsage.parse_modules(body.text())
}

///|
async fn fetch_manifest(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  guard valid_module_name(name) else { fail("invalid Mooncakes module name") }
  fetch_asset(
    "https://mooncakes.io/api/v0/manifest/\{name}",
    "Mooncakes manifest API",
  )
}

///|
async fn fetch_module_index(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  let version = argument_string(arguments, "version")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/module_index.json"
  @moonsage.compact_module_index(fetch_asset(url, "Mooncakes module index"))
}

///|
async fn fetch_package_docs(arguments : String) -> String {
  let name = argument_string(arguments, "name")
  let version = argument_string(arguments, "version")
  let path = argument_string(arguments, "package_path")
  guard valid_module_name(name) && valid_asset_value(version) else {
    fail("invalid module name or version")
  }
  let relpath = package_relpath(name, path)
  let url = "https://assets.mooncakes.io/assets/\{name}@\{version}/\{relpath}/package_data.json"
  @moonsage.compact_package_docs(fetch_asset(url, "Mooncakes package docs"))
}

///|
async fn fetch_asset(url : String, error_label : String) -> String {
  let (response, body) = @http.get(url, headers=asset_headers())
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
