///|
pub(all) struct ModuleSummary {
  name : String
  version : String
  license : String
  repository : String
  keywords : Array[String]
  description : String
  created_at : String
} derive(Eq, Debug, ToJson)

///|
pub(all) struct SearchResult {
  item : ModuleSummary
  score : Int
} derive(Eq, Debug, ToJson)

///|
let max_module_index_packages = 80

///|
let max_package_docs_entries = 100

///|
pub(all) enum AgentEvent {
  Plan(String)
  ToolCall(String)
  Observation(String)
} derive(Eq, Debug)

///|
pub(all) struct AgentAnswer {
  query : String
  events : Array[AgentEvent]
  results : Array[SearchResult]
} derive(Eq, Debug)

///|
pub(all) struct PackageIndexSummary {
  path : String
  traits : Array[String]
  errors : Array[String]
  types : Array[String]
  values : Array[String]
} derive(Eq, Debug, ToJson)

///|
pub(all) struct PackageApiEntry {
  kind : String
  name : String
  signature : String
  docstring : String
} derive(Eq, Debug, ToJson)

///|
pub(all) struct PackageDocsSummary {
  name : String
  entries : Array[PackageApiEntry]
  truncated : Bool
} derive(Eq, Debug, ToJson)

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
  output : Array[PackageIndexSummary],
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
  let packages : Array[PackageIndexSummary] = []
  collect_package_indexes(document, packages)
  if packages.length() > max_module_index_packages {
    packages.truncate(max_module_index_packages)
  }
  packages.to_json().stringify()
}

///|
fn push_api_entry(
  output : Array[PackageApiEntry],
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
  output : Array[PackageApiEntry],
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
  let entries : Array[PackageApiEntry] = []
  collect_api_group(document, "traits", "trait", entries)
  collect_api_group(document, "errors", "error", entries)
  collect_api_group(document, "types", "type", entries)
  collect_api_group(document, "values", "value", entries)
  let truncated = entries.length() > max_package_docs_entries
  if truncated {
    entries.truncate(max_package_docs_entries)
  }
  PackageDocsSummary::{
    name: json_string(document, "name"),
    entries,
    truncated,
  }
  .to_json()
  .stringify()
}

///|
pub fn parse_modules(text : String) -> Array[ModuleSummary] raise {
  let document = @json.parse(text)
  guard document is Array(items) else {
    fail("Mooncakes modules response must be a JSON array")
  }
  let modules : Array[ModuleSummary] = []
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

///|
fn query_terms(query : String) -> Array[String] {
  let terms : Array[String] = []
  for part in query.to_lower().split(" ") {
    let term = part.trim().to_owned()
    if term != "" && term != "find" && term != "package" && term != "library" {
      terms.push(term)
    }
  }
  terms
}

///|
fn module_haystack(item : ModuleSummary) -> String {
  let buffer = StringBuilder::new()
  buffer.write_string(item.name)
  buffer.write_char(' ')
  buffer.write_string(item.description)
  buffer.write_char(' ')
  buffer.write_string(item.license)
  for keyword in item.keywords {
    buffer.write_char(' ')
    buffer.write_string(keyword)
  }
  buffer.to_string().to_lower()
}

///|
fn score_module(item : ModuleSummary, terms : Array[String]) -> Int {
  let haystack = module_haystack(item)
  let name = item.name.to_lower()
  let mut score = 0
  for term in terms {
    if name.contains(term) {
      score += 5
    }
    if haystack.contains(term) {
      score += 2
    }
  }
  score
}

///|
pub fn search_modules(
  modules : Array[ModuleSummary],
  query : String,
  limit? : Int = 5,
) -> Array[SearchResult] {
  let terms = query_terms(query)
  let results : Array[SearchResult] = []
  for item in modules {
    let score = score_module(item, terms)
    if score > 0 {
      results.push({ item, score })
    }
  }
  results.sort_by(compare_results)
  if results.length() > limit {
    results.truncate(limit)
  }
  results
}

///|
fn compare_results(a : SearchResult, b : SearchResult) -> Int {
  if a.score != b.score {
    b.score - a.score
  } else if a.item.name < b.item.name {
    -1
  } else if a.item.name > b.item.name {
    1
  } else {
    0
  }
}

///|
pub fn run_agent(
  modules : Array[ModuleSummary],
  query : String,
  limit? : Int = 5,
) -> AgentAnswer {
  let events = [
    Plan("Search Mooncakes metadata, rank candidates, then cite package pages"),
    ToolCall("search_modules(query=\"\{query}\", limit=\{limit})"),
  ]
  let results = search_modules(modules, query, limit~)
  events.push(Observation("\{results.length()} matching modules selected"))
  { query, events, results }
}

///|
pub fn package_url(name : String) -> String {
  "https://mooncakes.io/docs/\{name}"
}

///|
pub fn render_answer(answer : AgentAnswer) -> String {
  let out = StringBuilder::new()
  out.write_string("MoonSage\n\n")
  for event in answer.events {
    match event {
      Plan(text) => out.write_string("[plan] \{text}\n")
      ToolCall(text) => out.write_string("[tool] \{text}\n")
      Observation(text) => out.write_string("[observation] \{text}\n")
    }
  }
  out.write_string("\n")
  if answer.results.is_empty() {
    out.write_string(
      "No matching modules found. Try more specific English keywords.\n",
    )
  } else {
    let mut index = 1
    for result in answer.results {
      let item = result.item
      out.write_string("\{index}. \{item.name} \{item.version}\n")
      if item.description != "" {
        out.write_string("   \{item.description}\n")
      }
      out.write_string("   license: \{item.license} | score: \{result.score}\n")
      out.write_string("   \{package_url(item.name)}\n")
      index += 1
    }
  }
  out.to_string()
}
