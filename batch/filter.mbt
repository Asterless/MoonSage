///|
fn valid_repo_component(value : String) -> Bool {
  if value.length() < 1 || value.length() > 100 || value == "." || value == ".." {
    return false
  }
  for code_unit in value {
    let code = code_unit.to_int()
    let valid = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !valid {
      return false
    }
  }
  true
}

///|
/// Parse a canonical public GitHub repository URL. Query strings, fragments,
/// extra path components and non-HTTPS schemes are rejected.
pub fn parse_github_repository(url : String) -> (String, String)? {
  let value = url.trim().to_owned()
  let prefix = "https://github.com/"
  guard value.to_lower().has_prefix(prefix) else { return None }
  guard !value.contains("?") &&
    !value.contains("#") &&
    !value.contains("\\") else { return None }
  let path = value[prefix.length():].trim_end(chars="/").to_owned()
  let parts = path.split("/").to_array()
  guard parts.length() == 2 else { return None }
  let owner = parts[0].to_owned()
  let raw_repo = parts[1].to_owned()
  let repo = if raw_repo.to_lower().has_suffix(".git") {
    raw_repo[:raw_repo.length() - 4].to_owned()
  } else {
    raw_repo
  }
  guard valid_repo_component(owner) && valid_repo_component(repo) else {
    return None
  }
  Some((owner.to_lower(), repo.to_lower()))
}

///|
pub fn normalize_github_repository(url : String) -> String? {
  match parse_github_repository(url) {
    Some((owner, repo)) => Some("https://github.com/\{owner}/\{repo}")
    None => None
  }
}

///|
fn glob_match_from(
  pattern : String,
  pattern_index : Int,
  value : String,
  value_index : Int,
) -> Bool {
  if pattern_index == pattern.length() {
    return value_index == value.length()
  }
  if pattern[pattern_index] == '*' {
    let mut next = pattern_index
    while next < pattern.length() && pattern[next] == '*' {
      next += 1
    }
    for index = value_index; index <= value.length(); index = index + 1 {
      if glob_match_from(pattern, next, value, index) {
        return true
      }
    }
    return false
  }
  if value_index < value.length() &&
    (pattern[pattern_index] == '?' || pattern[pattern_index] == value[value_index]) {
    return glob_match_from(pattern, pattern_index + 1, value, value_index + 1)
  }
  false
}

///|
pub fn batch_glob_match(pattern : String, value : String) -> Bool {
  glob_match_from(pattern.to_lower(), 0, value.to_lower(), 0)
}

///|
fn any_pattern_matches(patterns : Array[String], values : Array[String]) -> Bool {
  if patterns.is_empty() {
    return true
  }
  for pattern in patterns {
    for value in values {
      if batch_glob_match(pattern, value) {
        return true
      }
    }
  }
  false
}

///|
fn module_registry_owner(name : String) -> String {
  match name.split_once("/") {
    Some((owner, _)) => owner.to_owned().to_lower()
    None => ""
  }
}

///|
fn module_matches_filter(
  summary : @moonsage.ModuleSummary,
  repo_owner : String,
  normalized_repository : String,
  config : BatchConfig,
) -> Bool {
  let include_ok = any_pattern_matches(config.includes, [summary.name])
  let owner_ok = if config.owners.is_empty() {
    true
  } else {
    let registry_owner = module_registry_owner(summary.name)
    config.owners.any(fn(owner) {
      let wanted = owner.to_lower()
      wanted == registry_owner || wanted == repo_owner
    })
  }
  let keyword_ok = if config.keywords.is_empty() {
    true
  } else {
    config.keywords.any(fn(wanted) {
      summary.keywords.any(fn(actual) { actual.to_lower() == wanted.to_lower() })
    })
  }
  let excluded = !config.excludes.is_empty() &&
    any_pattern_matches(config.excludes, [summary.name, normalized_repository])
  include_ok && owner_ok && keyword_ok && !excluded
}

///|
fn compare_batch_module(a : BatchModule, b : BatchModule) -> Int {
  let repository_order = a.repository.compare(b.repository)
  if repository_order != 0 {
    repository_order
  } else {
    a.primary_name.compare(b.primary_name)
  }
}

///|
/// Filter a Mooncakes snapshot and collapse modules that point at the same
/// GitHub repository. The result is deterministic and `limit` is applied only
/// after repository de-duplication and sorting.
pub fn filter_modules(
  modules : Array[@moonsage.ModuleSummary],
  config : BatchConfig,
) -> Array[BatchModule] raise {
  validate_batch_config(config)
  let grouped : Array[BatchModule] = []
  let indexes : Map[String, Int] = Map([])
  let versions : Map[String, Array[String]] = Map([])
  for summary in modules {
    guard parse_github_repository(summary.repository) is Some((owner, repo)) else {
      continue
    }
    let repository = "https://github.com/\{owner}/\{repo}"
    guard module_matches_filter(summary, owner, repository, config) else {
      continue
    }
    let key = owner + "--" + repo
    match indexes.get(repository) {
      Some(index) => {
        if !grouped[index].module_names.contains(summary.name) {
          grouped[index].module_names.push(summary.name)
          grouped[index].module_names.sort_by(fn(a, b) { a.compare(b) })
          let entries = versions[repository]
          entries.push(summary.name + "@" + summary.version)
          entries.sort_by(fn(a, b) { a.compare(b) })
          grouped[index].version = entries.join("|")
        }
      }
      None => {
        indexes[repository] = grouped.length()
        versions[repository] = [summary.name + "@" + summary.version]
        grouped.push({
          key,
          owner,
          repo,
          repository,
          primary_name: summary.name,
          module_names: [summary.name],
          version: summary.version,
        })
      }
    }
  }
  grouped.sort_by(compare_batch_module)
  if config.limit > 0 && grouped.length() > config.limit {
    grouped.truncate(config.limit)
  }
  grouped
}

///|
pub fn batch_fingerprint(
  owner : String,
  repo : String,
  source_revision : String,
  policy_hash : String,
) -> String {
  "\{owner.to_lower()}/\{repo.to_lower()}@\{source_revision}#\{policy_hash}"
}

///|
pub fn validate_storage_id(value : String) -> Unit raise {
  guard value.length() >= 1 && value.length() <= 160 else {
    fail("storage id must contain 1 to 160 characters")
  }
  guard value != "." && value != ".." else { fail("invalid storage id") }
  for code_unit in value {
    let code = code_unit.to_int()
    let valid = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    guard valid else { fail("invalid storage id: \{value}") }
  }
}
