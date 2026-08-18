///|
let max_module_index_packages = 80

///|
let max_package_docs_entries = 100

///|
fn json_string(value : Json, key : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
fn json_strings(value : Json, key : String) -> Array[String] {
  let result : Array[String] = []
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(items)) =>
          for item in items {
            if item is String(text) {
              result.push(text)
            }
          }
        _ => ()
      }
    _ => ()
  }
  result
}

///|
fn json_names(value : Json, key : String) -> Array[String] {
  let result : Array[String] = []
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(text) => result.push(text)
              Object(_) => {
                let name = json_string(item, "name")
                if name != "" {
                  result.push(name)
                }
              }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  result
}

///|
fn collect_package_indexes(
  node : Json,
  output : Array[@types.PackageIndexSummary],
) -> Unit {
  guard node is Object(fields) else { return }
  if fields.get("package") is Some(package_data) && package_data is Object(_) {
    let path = json_string(package_data, "path")
    if path != "" {
      output.push({
        path,
        traits: json_names(package_data, "traits"),
        errors: json_names(package_data, "errors"),
        types: json_names(package_data, "types"),
        values: json_names(package_data, "values"),
      })
    }
  }
  if fields.get("childs") is Some(Array(children)) {
    for child in children {
      collect_package_indexes(child, output)
    }
  }
}

///|
pub fn compact_module_index(text : String) -> String raise {
  let document = @json.parse(text)
  let packages : Array[@types.PackageIndexSummary] = []
  collect_package_indexes(document, packages)
  if packages.length() > max_module_index_packages {
    packages.truncate(max_module_index_packages)
  }
  packages.to_json().stringify()
}

///|
fn push_api_entry(
  output : Array[@types.PackageApiEntry],
  kind : String,
  value : Json,
  name_prefix? : String = "",
) -> Unit {
  let name = json_string(value, "name")
  if name != "" {
    let full_name = if name_prefix == "" { name } else { name_prefix + name }
    output.push({
      kind,
      name: full_name,
      signature: json_string(value, "signature"),
      docstring: json_string(value, "docstring"),
    })
  }
}

///|
fn collect_api_group(
  document : Json,
  key : String,
  kind : String,
  output : Array[@types.PackageApiEntry],
) -> Unit {
  guard document is Object(fields) else { return }
  if fields.get(key) is Some(Array(items)) {
    for item in items {
      push_api_entry(output, kind, item)
      if item is Object(item_fields) &&
        item_fields.get("methods") is Some(Array(methods)) {
        let owner = json_string(item, "name")
        for method_data in methods {
          push_api_entry(
            output,
            "method",
            method_data,
            name_prefix="\{owner}::",
          )
        }
      }
    }
  }
}

///|
pub fn compact_package_docs(text : String) -> String raise {
  let document = @json.parse(text)
  guard document is Object(_) else {
    fail("Mooncakes package data must be a JSON object")
  }
  let entries : Array[@types.PackageApiEntry] = []
  collect_api_group(document, "traits", "trait", entries)
  collect_api_group(document, "errors", "error", entries)
  collect_api_group(document, "types", "type", entries)
  collect_api_group(document, "values", "value", entries)
  let truncated = entries.length() > max_package_docs_entries
  if truncated {
    entries.truncate(max_package_docs_entries)
  }
  @types.PackageDocsSummary::{
    name: json_string(document, "name"),
    entries,
    truncated,
  }
  .to_json()
  .stringify()
}

///|
pub fn parse_modules(text : String) -> Array[@types.ModuleSummary] raise {
  let document = @json.parse(text)
  guard document is Array(items) else {
    fail("Mooncakes modules response must be a JSON array")
  }
  let modules : Array[@types.ModuleSummary] = []
  for item in items {
    let name = json_string(item, "name")
    if name != "" {
      modules.push({
        name,
        version: json_string(item, "version"),
        license: json_string(item, "license"),
        repository: json_string(item, "repository"),
        keywords: json_strings(item, "keywords"),
        description: json_string(item, "description"),
        created_at: json_string(item, "created_at"),
      })
    }
  }
  modules
}
