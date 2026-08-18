///|
test "query_terms lowercases, trims and drops stopwords" {
  assert_eq(query_terms("  Find HTTP  Client "), ["http", "client"])
  assert_eq(query_terms("package library"), [])
  assert_eq(query_terms(""), [])
}

///|
test "score_module weights name matches above description" {
  let item = @types.ModuleSummary::{
    name: "owner/http-kit",
    version: "1.0.0",
    license: "MIT",
    repository: "",
    keywords: ["http"],
    description: "A client for requests",
    created_at: "",
  }
  assert_true(score_module(item, ["http"]) > score_module(item, ["requests"]))
}

///|
test "module_haystack covers name, description, license and keywords" {
  let item = @types.ModuleSummary::{
    name: "Owner/Mod",
    version: "1.0.0",
    license: "MIT",
    repository: "",
    keywords: ["native"],
    description: "Fast IO",
    created_at: "",
  }
  let haystack = module_haystack(item)
  assert_true(haystack.contains("owner/mod"))
  assert_true(haystack.contains("fast io"))
  assert_true(haystack.contains("mit"))
  assert_true(haystack.contains("native"))
}

///|
test "compare_results orders by score then name" {
  let a = @types.SearchResult::{
    item: @types.ModuleSummary::{
      name: "owner/a",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "",
      created_at: "",
    },
    score: 5,
  }
  let b = @types.SearchResult::{
    item: @types.ModuleSummary::{
      name: "owner/b",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "",
      created_at: "",
    },
    score: 5,
  }
  let higher = @types.SearchResult::{
    item: @types.ModuleSummary::{
      name: "owner/c",
      version: "1.0.0",
      license: "MIT",
      repository: "",
      keywords: [],
      description: "",
      created_at: "",
    },
    score: 7,
  }
  assert_true(compare_results(a, b) < 0)
  assert_true(compare_results(b, a) > 0)
  assert_eq(compare_results(a, a), 0)
  assert_true(compare_results(higher, a) < 0)
}
