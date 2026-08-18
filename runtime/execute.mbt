///|
fn trim_intermediate_content(content : String) -> String {
  let max = 2000
  if content.length() > max {
    content[:max].to_owned() + "\n... [intermediate analysis truncated]"
  } else {
    content
  }
}

///|
fn tool_result_status(result : String) -> String {
  let document = @json.parse(result) catch { _ => Json::null() }
  match document {
    Object(fields) =>
      if fields.get("error") is Some(_) || fields.get("isError") is Some(True) {
        "error"
      } else {
        "ok"
      }
    _ => "ok"
  }
}

///|
async fn emit_event(
  events : Array[EngineEvent],
  callback : async (EngineEvent) -> Unit,
  event : EngineEvent,
) -> Unit {
  events.push(event)
  callback(event)
}

///|
fn Agent::model_tools(self : Agent) -> Array[@ai.ModelTool] {
  self.tools.map(fn(tool) {
    {
      name: tool.schema.name,
      description: tool.schema.description,
      parameters: tool.schema.parameters,
    }
  })
}

///|
async fn complete_round(
  client : @ai.ChatClient,
  request : @ai.ChatRequest,
  round : Int,
  events : Array[EngineEvent],
  on_event : async (EngineEvent) -> Unit,
) -> @ai.ChatResponse {
  let reasoning_seen = [false]
  let response = client.complete(request, on_event=async fn(event) {
    match event {
      ContentDelta(_) => ()
      ReasoningDelta(text) =>
        if text != "" {
          reasoning_seen[0] = true
          emit_event(events, on_event, ThinkingDelta({ round, text }))
        }
      Retrying(attempt~, reason~) =>
        emit_event(events, on_event, Retrying({ attempt, reason }))
    }
  })
  if !reasoning_seen[0] && response.reasoning != "" {
    emit_event(
      events,
      on_event,
      ThinkingDelta({ round, text: response.reasoning }),
    )
  }
  response
}

///|
/// Execute one question in a fresh session.
pub async fn Agent::execute(
  self : Agent,
  client : @ai.ChatClient,
  question : String,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  let session = self.new_session()
  self.execute_turn(
    client,
    session,
    question,
    on_event~,
    context_window_tokens~,
    reserved_output_tokens~,
  )
}

///|
/// Execute one user turn against an existing persisted session.
pub async fn Agent::execute_turn(
  self : Agent,
  client : @ai.ChatClient,
  session : Session,
  question : String,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  session.messages.push(@ai.User(question).to_json())
  let model_tools = self.model_tools()
  let trace : Array[String] = ["[plan] Delegate the task to the model"]
  let events : Array[EngineEvent] = []
  let mut step = 0
  let mut total_tool_calls = 0
  let mut budget_exhausted = false
  while step < self.max_rounds && !budget_exhausted {
    if total_tool_calls >= self.max_tool_calls {
      budget_exhausted = true
      break
    }
    self.prepare_context(
      client, session, context_window_tokens, reserved_output_tokens,
    )
    let result = complete_round(
      client,
      {
        messages: @ai.messages_from_json(session.messages),
        tools: model_tools,
        max_tokens: self.max_tokens,
      },
      step,
      events,
      on_event,
    )
    if result.finish_reason is Length {
      trace.push("[observation] Model hit max_tokens; answer may be truncated")
    }
    if result.tool_calls.is_empty() {
      guard result.content != "" else { fail("model returned an empty answer") }
      if result.finish_reason is Length {
        trace.push(
          "[observation] Final answer hit max_tokens; requesting continuation",
        )
        session.messages.push(
          @ai.Assistant(content=result.content, tool_calls=[]).to_json(),
        )
        session.messages.push(
          @ai.User(
            "(System: continue and complete the answer exactly from where it stopped, keeping the same language and format. No tools are available now: output ONLY the plain Markdown answer, never tool calls or XML.)",
          ).to_json(),
        )
        self.prepare_context(
          client, session, context_window_tokens, reserved_output_tokens,
        )
        let continuation = complete_round(
          client,
          {
            messages: @ai.messages_from_json(session.messages),
            tools: [],
            max_tokens: self.max_tokens,
          },
          step,
          events,
          on_event,
        )
        let text = if continuation.content != "" {
          result.content + "\n" + continuation.content
        } else {
          result.content
        }
        session.messages.push(
          @ai.Assistant(content=text, tool_calls=[]).to_json(),
        )
        emit_event(events, on_event, FinalStarted)
        emit_event(events, on_event, FinalDelta(text))
        trace.push("[final] Model returned an answer (continued)")
        return { text, trace, events }
      }
      session.messages.push(
        @ai.Assistant(content=result.content, tool_calls=[]).to_json(),
      )
      emit_event(events, on_event, FinalStarted)
      emit_event(events, on_event, FinalDelta(result.content))
      trace.push("[final] Model returned an answer")
      return { text: result.content, trace, events }
    }
    let intermediate = trim_intermediate_content(result.content)
    if intermediate != "" {
      emit_event(
        events,
        on_event,
        ThinkingDelta({ round: step, text: intermediate }),
      )
    }
    session.messages.push(
      @ai.Assistant(content=intermediate, tool_calls=result.tool_calls).to_json(),
    )
    let mut call_index = 0
    while call_index < result.tool_calls.length() {
      let call = result.tool_calls[call_index]
      if total_tool_calls >= self.max_tool_calls {
        budget_exhausted = true
        session.messages.push(
          @ai.Tool(
            tool_call_id=call.id,
            content=@tools.error_json(
              "tool call skipped: agent budget exhausted",
            ),
          ).to_json(),
        )
        call_index += 1
        continue
      }
      if call.name == "delegate_task" {
        let delegated_calls : Array[@ai.ModelToolCall] = []
        while call_index < result.tool_calls.length() &&
              result.tool_calls[call_index].name == "delegate_task" &&
              total_tool_calls < self.max_tool_calls {
          let delegated = result.tool_calls[call_index]
          delegated_calls.push(delegated)
          total_tool_calls += 1
          trace.push("[tool] \{delegated.name}")
          emit_event(
            events,
            on_event,
            ToolStarted({
              round: step,
              call_id: delegated.id,
              name: delegated.name,
              arguments: delegated.arguments,
            }),
          )
          call_index += 1
        }
        let tasks = delegated_calls.map(fn(delegated) {
          async fn() {
            match @tools.find_tool(self.tools, delegated.name) {
              Some(tool) =>
                tool.run(delegated.arguments) catch {
                  error => @tools.error_json(error.to_string())
                }
              None => @tools.error_json("unknown tool: \{delegated.name}")
            }
          }
        })
        let delegated_results = @async.all(tasks, max_concurrent=3)
        for i in 0..<delegated_calls.length() {
          let delegated = delegated_calls[i]
          let call_result = delegated_results[i]
          emit_event(
            events,
            on_event,
            ToolFinished({
              round: step,
              call_id: delegated.id,
              name: delegated.name,
              status: tool_result_status(call_result),
              result: call_result,
            }),
          )
          session.messages.push(
            @ai.Tool(tool_call_id=delegated.id, content=call_result).to_json(),
          )
          trace.push("[observation] \{delegated.name} completed")
        }
        continue
      }
      total_tool_calls += 1
      trace.push("[tool] \{call.name}")
      emit_event(
        events,
        on_event,
        ToolStarted({
          round: step,
          call_id: call.id,
          name: call.name,
          arguments: call.arguments,
        }),
      )
      let call_result = match @tools.find_tool(self.tools, call.name) {
        Some(tool) => tool.run(call.arguments)
        None => @tools.error_json("unknown tool: \{call.name}")
      }
      emit_event(
        events,
        on_event,
        ToolFinished({
          round: step,
          call_id: call.id,
          name: call.name,
          status: tool_result_status(call_result),
          result: call_result,
        }),
      )
      session.messages.push(
        @ai.Tool(tool_call_id=call.id, content=call_result).to_json(),
      )
      trace.push("[observation] \{call.name} completed")
      call_index += 1
    }
    step += 1
  }
  if !budget_exhausted && step >= self.max_rounds {
    budget_exhausted = true
  }
  if budget_exhausted {
    trace.push(
      "[observation] Agent budget exhausted; requesting a final answer from collected evidence",
    )
    session.messages.push(
      @ai.User(
        "(System: no more tool calls are allowed. Answer the user's question now using the evidence already collected. No tools are available: output ONLY the plain Markdown answer, never tool calls or XML.)",
      ).to_json(),
    )
    self.prepare_context(
      client, session, context_window_tokens, reserved_output_tokens,
    )
    let result = complete_round(
      client,
      {
        messages: @ai.messages_from_json(session.messages),
        tools: [],
        max_tokens: self.max_tokens,
      },
      step,
      events,
      on_event,
    )
    if result.content != "" {
      let mut text = result.content
      session.messages.push(
        @ai.Assistant(content=result.content, tool_calls=[]).to_json(),
      )
      if result.finish_reason is Length {
        trace.push(
          "[observation] Final answer hit max_tokens; requesting continuation",
        )
        session.messages.push(
          @ai.User(
            "(System: continue and complete the answer exactly from where it stopped, keeping the same language and format. Output ONLY the plain Markdown answer.)",
          ).to_json(),
        )
        self.prepare_context(
          client, session, context_window_tokens, reserved_output_tokens,
        )
        let continuation = complete_round(
          client,
          {
            messages: @ai.messages_from_json(session.messages),
            tools: [],
            max_tokens: self.max_tokens,
          },
          step,
          events,
          on_event,
        )
        if continuation.content != "" {
          text = text + "\n" + continuation.content
          session.messages.push(
            @ai.Assistant(content=continuation.content, tool_calls=[]).to_json(),
          )
        }
        trace.push("[final] Model answered from collected evidence (continued)")
      } else {
        trace.push("[final] Model answered from collected evidence")
      }
      emit_event(events, on_event, FinalStarted)
      emit_event(events, on_event, FinalDelta(text))
      return { text, trace, events }
    }
    fail("model could not answer after exhausting the agent budget")
  }
  fail("agent loop terminated without an answer")
}
