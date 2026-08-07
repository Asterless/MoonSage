///|
test "safe_path allows relative files and blocks traversal" {
  let root = "C:/work/proj"
  assert_eq(safe_path(root, "src/a.mbt"), "C:/work/proj/src/a.mbt")
  assert_eq(safe_path(root, "moon.mod"), "C:/work/proj/moon.mod")
  let blocked = try {
    ignore(safe_path(root, "../evil"))
    false
  } catch {
    _ => true
  }
  assert_true(blocked)
  let nested = try {
    ignore(safe_path(root, "src/../../evil"))
    false
  } catch {
    _ => true
  }
  assert_true(nested)
  let absolute = try {
    ignore(safe_path(root, "/etc/passwd"))
    false
  } catch {
    _ => true
  }
  assert_true(absolute)
  let win_abs = try {
    ignore(safe_path(root, "C:\\evil"))
    false
  } catch {
    _ => true
  }
  assert_true(win_abs)
  let drive = try {
    ignore(safe_path(root, "C:/evil"))
    false
  } catch {
    _ => true
  }
  assert_true(drive)
  let empty = try {
    ignore(safe_path(root, ""))
    false
  } catch {
    _ => true
  }
  assert_true(empty)
}

///|
test "parse_int_or falls back to default" {
  assert_eq(parse_int_or("42", 0), 42)
  assert_eq(parse_int_or("0", 9), 0)
  assert_eq(parse_int_or("-3", 9), -3)
  assert_eq(parse_int_or("  7 ", 1), 1)
  assert_eq(parse_int_or("abc", 7), 7)
  assert_eq(parse_int_or("", 2), 2)
}

///|
test "json_string_arg reads string fields only" {
  let doc = @json.parse("{\"path\":\"a.mbt\",\"n\":1}")
  assert_eq(json_string_arg(doc, "path"), "a.mbt")
  assert_eq(json_string_arg(doc, "n"), "")
  assert_eq(json_string_arg(doc, "missing"), "")
}

///|
test "basename returns the last path component" {
  assert_eq(basename("a/b/c.mbt"), "c.mbt")
  assert_eq(basename("src/main.mbt"), "main.mbt")
  assert_eq(basename("moon.mod"), "moon.mod")
}
