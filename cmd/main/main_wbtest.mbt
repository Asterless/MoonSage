///|
test "join_query joins arguments from the start index" {
  assert_eq(join_query(["moon", "run", "ask", "a", "b"], 2), "ask a b")
  assert_eq(join_query(["search", "json"], 0), "search json")
}
