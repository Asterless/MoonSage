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
