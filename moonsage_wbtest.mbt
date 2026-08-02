// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "query_terms lowercases, trims and drops stopwords" {
  assert_eq(query_terms("  Find HTTP  Client "), ["http", "client"])
  assert_eq(query_terms("package library"), [])
  assert_eq(query_terms(""), [])
}

///|
test "score_module weights name matches above description" {
  let item : ModuleSummary = {
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
  let item : ModuleSummary = {
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
test "json_string returns empty for missing keys or non-objects" {
  assert_eq(
    json_string(Json::object({ "name": Json::string("x") }), "missing"),
    "",
  )
  assert_eq(json_string(Json::string("not-an-object"), "name"), "")
}

///|
test "json_strings collects only string arrays" {
  let value = Json::object({
    "tags": Json::array([Json::string("a"), Json::string("b")]),
  })
  assert_eq(json_strings(value, "tags"), ["a", "b"])
  assert_eq(
    json_strings(Json::object({ "tags": Json::string("oops") }), "tags"),
    [],
  )
  assert_eq(json_strings(Json::string("x"), "tags"), [])
}

///|
test "json_names collects plain strings and object names" {
  let value = Json::object({
    "items": Json::array([
      Json::string("plain"),
      Json::object({ "name": Json::string("typed") }),
      Json::object({ "other": Json::string("x") }),
      Json::number(42.0),
    ]),
  })
  assert_eq(json_names(value, "items"), ["plain", "typed"])
  assert_eq(json_names(Json::object({}), "items"), [])
  assert_eq(json_names(Json::string("x"), "items"), [])
}

///|
test "compare_results orders by score then name" {
  let a = {
    item: {
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
  let b = {
    item: {
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
  let higher = {
    item: {
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
