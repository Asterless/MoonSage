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
fn module_haystack(item : @types.ModuleSummary) -> String {
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
fn score_module(item : @types.ModuleSummary, terms : Array[String]) -> Int {
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
  modules : Array[@types.ModuleSummary],
  query : String,
  limit? : Int = 5,
) -> Array[@types.SearchResult] {
  let terms = query_terms(query)
  let results : Array[@types.SearchResult] = []
  for item in modules {
    let score = score_module(item, terms)
    if score > 0 {
      results.push(@types.SearchResult::{ item, score })
    }
  }
  results.sort_by(compare_results)
  if results.length() > limit {
    results.truncate(limit)
  }
  results
}

///|
fn compare_results(a : @types.SearchResult, b : @types.SearchResult) -> Int {
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
