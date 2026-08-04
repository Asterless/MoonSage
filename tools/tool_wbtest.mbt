///|
test "error_json wraps messages in a JSON object" {
  assert_eq(error_json("boom"), "{\"error\":\"boom\"}")
}

///|
test "argument_string extracts required arguments" {
  let ok = argument_string("{\"query\":\"http\"}", "query") catch { _ => "" }
  assert_eq(ok, "http")
  let raised = try {
    ignore(argument_string("{}", "query"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
