///|
test "event_to_json preserves canonical names and fields" {
  assert_eq(
    @protocol.event_to_json(ThinkingDelta({ round: 1, text: "reason" })).stringify(),
    "{\"type\":\"thinking_delta\",\"round\":1,\"text\":\"reason\"}",
  )
  assert_eq(
    @protocol.event_to_json(
      ToolStarted({
        round: 2,
        call_id: "call-1",
        name: "inspect",
        arguments: "{}",
      }),
    ).stringify(),
    "{\"type\":\"tool_started\",\"round\":2,\"call_id\":\"call-1\",\"name\":\"inspect\",\"arguments\":\"{}\"}",
  )
  assert_eq(
    @protocol.event_to_json(
      ToolFinished({
        round: 2,
        call_id: "call-1",
        name: "inspect",
        status: "ok",
        result: "result",
      }),
    ).stringify(),
    "{\"type\":\"tool_finished\",\"round\":2,\"call_id\":\"call-1\",\"name\":\"inspect\",\"status\":\"ok\",\"result\":\"result\"}",
  )
  assert_eq(
    @protocol.event_to_json(FinalStarted).stringify(),
    "{\"type\":\"final_started\"}",
  )
  assert_eq(
    @protocol.event_to_json(FinalDelta("answer")).stringify(),
    "{\"type\":\"final_delta\",\"text\":\"answer\"}",
  )
  assert_eq(
    @protocol.event_to_json(Retrying({ attempt: 3, reason: "reset" })).stringify(),
    "{\"type\":\"retrying\",\"attempt\":3,\"reason\":\"reset\"}",
  )
  assert_eq(
    @protocol.event_to_json(Warning("careful")).stringify(),
    "{\"type\":\"warning\",\"message\":\"careful\"}",
  )
  assert_eq(
    @protocol.event_to_json(Error("failed")).stringify(),
    "{\"type\":\"error\",\"message\":\"failed\"}",
  )
}
