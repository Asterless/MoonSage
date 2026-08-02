///|
test "valid_module_name rejects traversal and query characters" {
  assert_true(valid_module_name("owner/module"))
  assert_true(!valid_module_name("owner"))
  assert_true(!valid_module_name("owner/module/../evil"))
  assert_true(!valid_module_name("owner/mod?ule"))
  assert_true(!valid_module_name("owner/mod\\ule"))
}

///|
test "valid_asset_value rejects separators and empty strings" {
  assert_true(valid_asset_value("1.2.3"))
  assert_true(!valid_asset_value(""))
  assert_true(!valid_asset_value("1.2.3/../x"))
  assert_true(!valid_asset_value("v?1"))
}

///|
test "package_relpath strips the module prefix" {
  assert_eq(package_relpath("owner/mod", "owner/mod/client"), "client")
  assert_eq(package_relpath("owner/mod", "owner/mod"), "mod")
  assert_eq(package_relpath("owner/mod", "other/thing"), "other/thing")
}

///|
test "package_relpath rejects unsafe paths" {
  let raised = try {
    ignore(package_relpath("owner/mod", "owner/mod/../x"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "join_query joins arguments from the start index" {
  assert_eq(join_query(["moon", "run", "ask", "a", "b"], 2), "ask a b")
  assert_eq(join_query(["search", "json"], 0), "search json")
}

///|
test "error_json wraps messages in a JSON object" {
  assert_eq(error_json("boom"), "{\"error\":\"boom\"}")
}
