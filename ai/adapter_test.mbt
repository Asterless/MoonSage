///|
test "provider finish reasons are normalized" {
  assert_eq(@ai.normalize_finish_reason(None), Stop)
  assert_eq(@ai.normalize_finish_reason(Some("stop")), Stop)
  assert_eq(@ai.normalize_finish_reason(Some("end_turn")), Stop)
  assert_eq(@ai.normalize_finish_reason(Some("length")), Length)
  assert_eq(@ai.normalize_finish_reason(Some("max_tokens")), Length)
  assert_eq(@ai.normalize_finish_reason(Some("tool_calls")), ToolCalls)
  assert_eq(@ai.normalize_finish_reason(Some("tool_use")), ToolCalls)
  assert_eq(
    @ai.normalize_finish_reason(Some("content_filter")),
    Other("content_filter"),
  )
}
