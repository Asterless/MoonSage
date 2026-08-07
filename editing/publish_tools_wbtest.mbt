///|
test "valid_component accepts safe names" {
  assert_true(valid_component("foo"))
  assert_true(valid_component("foo.bar-1_2"))
  assert_true(valid_component("a"))
  assert_true(valid_component("MoonPtime"))
}

///|
test "valid_component rejects traversal and junk" {
  assert_eq(valid_component(""), false)
  assert_eq(valid_component("."), false)
  assert_eq(valid_component(".."), false)
  assert_eq(valid_component("%2e%2e"), false)
  assert_eq(valid_component("a b"), false)
  assert_eq(valid_component("a/b"), false)
  assert_eq(valid_component("a\\b"), false)
  assert_eq(valid_component("a:b"), false)
  let long = StringBuilder::new()
  for i = 0; i < 101; i = i + 1 {
    long.write_string("a")
  }
  assert_eq(valid_component(long.to_string()), false)
}

///|
test "parse_github_url accepts valid GitHub URLs" {
  assert_eq(
    parse_github_url("https://github.com/moonbitlang/core"),
    Some(("moonbitlang", "core")),
  )
  assert_eq(
    parse_github_url("https://github.com/moonbitlang/core.git"),
    Some(("moonbitlang", "core")),
  )
  assert_eq(
    parse_github_url("https://github.com/moonbitlang/core/"),
    Some(("moonbitlang", "core")),
  )
}

///|
test "parse_github_url rejects traversal or invalid components" {
  assert_eq(parse_github_url("https://github.com/owner/.."), None)
  assert_eq(parse_github_url("https://github.com/.."), None)
  assert_eq(parse_github_url("https://github.com/owner/..%2e"), None)
  assert_eq(parse_github_url("https://github.com/o wner/repo"), None)
  assert_eq(parse_github_url("https://github.com/owner/repo\\x"), None)
}

///|
test "resolve_clone_target_name derives safe target names" {
  assert_eq(
    resolve_clone_target_name("https://github.com/moonbitlang/core", ""),
    "core",
  )
  assert_eq(resolve_clone_target_name("https://example.com/foo/bar", ""), "bar")
  assert_eq(resolve_clone_target_name("", "core"), "core")
  let raised = try {
    ignore(resolve_clone_target_name("https://example.com/foo/..", ""))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  let raised2 = try {
    ignore(resolve_clone_target_name("https://github.com/owner/..", ""))
    false
  } catch {
    _ => true
  }
  assert_true(raised2)
  let raised3 = try {
    ignore(resolve_clone_target_name("", ".."))
    false
  } catch {
    _ => true
  }
  assert_true(raised3)
}
