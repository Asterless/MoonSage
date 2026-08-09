///|
pub(all) struct Agent {
  system_prompt : String
  tools : Array[@tools.Tool]
  max_tool_calls : Int
  max_rounds : Int
  max_tokens : Int
}

///|
// Intermediate rounds (those that end in tool calls) usually carry the
// model's reasoning narrative, which adds little for later decisions but
// inflates the context. Trim it; the final report round is not affected.
fn trim_intermediate_content(content : String) -> String {
  let max = 2000
  if content.length() > max {
    content[:max].to_owned() + "\n... [intermediate analysis truncated]"
  } else {
    content
  }
}

///|
// 一次会话的持久状态：完整消息历史跨回合保留，供交互式对话复用。
pub(all) struct Session {
  messages : Array[Json]
}

///|
// 会话序列化：消息本身已是 Json。
pub fn Session::to_json(self : Session) -> Json {
  Json::array(self.messages)
}

///|
pub fn Session::from_json(document : Json) -> Session {
  match document {
    Array(items) => { messages: items }
    _ => { messages: [] }
  }
}

///|
// 会话消息总字符数（粗略的上下文规模估计）。
pub fn Session::char_count(self : Session) -> Int {
  let mut total = 0
  for message in self.messages {
    total = total + message.stringify().length()
  }
  total
}

///|
// 粗略的 token 估算:英文约 4 字符/token,中文等其他字符约 1 字符/token。
// 用于决定何时压缩上下文,比纯字符数更接近模型计费口径。
pub fn Session::estimated_tokens(self : Session) -> Int {
  let mut ascii = 0
  let mut other = 0
  for message in self.messages {
    let text = message.stringify()
    for i = 0; i < text.length(); i = i + 1 {
      if text[i].to_int() < 128 {
        ascii += 1
      } else {
        other += 1
      }
    }
  }
  other + ascii / 4
}

///|
pub fn Agent::new_session(self : Agent) -> Session {
  { messages: [@llm.chat_message("system", self.system_prompt)] }
}

///|
// 引擎向前端（终端 / 未来 TUI / GUI）发出的事件流。前端只消费事件，
// 与渲染层完全解耦，便于替换成任意界面。
pub(all) struct ThinkingDeltaEvent {
  round : Int
  text : String
} derive(Eq, Debug)

///|
pub(all) struct ToolStartedEvent {
  round : Int
  call_id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
pub(all) struct ToolFinishedEvent {
  round : Int
  call_id : String
  name : String
  status : String
  result : String
} derive(Eq, Debug)

///|
pub(all) struct RetryEvent {
  attempt : Int
  reason : String
} derive(Eq, Debug)

///|
pub(all) enum EngineEvent {
  // 工具阶段的推理/过程文本（已按预算截断，空内容不发送）
  ThinkingDelta(ThinkingDeltaEvent)
  // 工具调用开始
  ToolStarted(ToolStartedEvent)
  // 工具调用完成
  ToolFinished(ToolFinishedEvent)
  // 最终回答增量（回合结束时一次性发送完整文本）
  FinalStarted
  FinalDelta(String)
  Retrying(RetryEvent)
  Warning(String)
  Error(String)
} derive(Eq, Debug)

///|
pub async fn ignore_event(_ : EngineEvent) -> Unit {
  @async.sleep(0)
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
fn message_role(message : Json) -> String {
  match message {
    Object(fields) =>
      match fields.get("role") {
        Some(String(role)) => role
        _ => ""
      }
    _ => ""
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
// 上下文压缩：当会话超过阈值字符数时，把较早的历史（保留系统提示和最近
// keep_recent 条消息）交给模型总结成一条摘要，替换掉旧消息。
pub async fn Agent::compact(
  self : Agent,
  session : Session,
  api_key : String,
  base_url : String,
  model : String,
  threshold_tokens? : Int = 8000,
  keep_recent_turns? : Int = 2,
  provider? : @llm.ProviderKind = @llm.OpenAi,
) -> Unit {
  if session.estimated_tokens() <= threshold_tokens {
    return
  }
  let keep_turns = if keep_recent_turns < 1 { 1 } else { keep_recent_turns }
  // 按"轮"保留:以 user 消息为轮次边界,从尾部向前保留最近的 keep_turns 轮。
  // 窗口起点恒为 user 消息,因此 assistant(tool_calls) 与其 tool 结果不会被
  // 切散,天然避免孤儿 tool 消息导致 API 400。
  let mut cut = session.messages.length() - 1
  let mut seen_users = 0
  while cut > 1 {
    if message_role(session.messages[cut]) == "user" {
      seen_users += 1
      if seen_users >= keep_turns {
        break
      }
    }
    cut = cut - 1
  }
  if cut <= 1 {
    return
  }
  let transcript = StringBuilder::new()
  for i = 1; i < cut; i = i + 1 {
    transcript.write_string(session.messages[i].stringify())
    transcript.write_string("\n")
  }
  let transcript_text = transcript.to_string()
  let transcript_limit = if threshold_tokens > 64 {
    threshold_tokens
  } else {
    64
  }
  let bounded_transcript = if transcript_text.length() > transcript_limit {
    transcript_text[:transcript_limit].to_owned() + "\n... [history truncated]"
  } else {
    transcript_text
  }
  let summary_tokens = if threshold_tokens / 2 < self.max_tokens {
    if threshold_tokens / 2 > 0 {
      threshold_tokens / 2
    } else {
      1
    }
  } else {
    self.max_tokens
  }
  guard summary_tokens > 0 else {
    fail("context window leaves no room for a compaction summary")
  }
  let summary_result = @llm.stream_chat_completion_provider(
    provider,
    api_key,
    base_url,
    model,
    [
      @llm.chat_message(
        "system", "Summarize the conversation history into a concise summary that preserves key facts, decisions, file changes and the user's requests. Output only the summary.",
      ),
      @llm.chat_message("user", bounded_transcript),
    ],
    [],
    max_tokens=summary_tokens,
    on_delta=@llm.ignore_delta,
  )
  let new_messages : Array[Json] = [session.messages[0]]
  if summary_result.content != "" {
    // 摘要成功:用摘要替换被裁剪的旧历史。
    new_messages.push(
      @llm.chat_message("user", "(会话摘要) " + summary_result.content),
    )
  } else {
    // 摘要失败回退:直接丢弃早期轮次,保留最近 keep_recent_turns 轮原文,
    // 保证长会话仍能继续,而不是无限膨胀。
    new_messages.push(
      @llm.chat_message(
        "user", "(会话历史过长,部分早期消息已被裁剪;以下为最近的对话)",
      ),
    )
  }
  for i = cut; i < session.messages.length(); i = i + 1 {
    new_messages.push(session.messages[i])
  }
  while session.messages.length() > 0 {
    ignore(session.messages.pop())
  }
  for message in new_messages {
    session.messages.push(message)
  }
}

///|
// Ensure the next request has room for its configured output reservation.
// Compaction keeps complete user turns, so assistant tool calls remain paired
// with their tool results.
async fn Agent::prepare_context(
  self : Agent,
  session : Session,
  api_key : String,
  base_url : String,
  model : String,
  context_window_tokens : Int,
  reserved_output_tokens : Int,
  provider : @llm.ProviderKind,
) -> Unit {
  if context_window_tokens <= 0 {
    return
  }
  let reserve = if reserved_output_tokens > 0 {
    reserved_output_tokens
  } else {
    self.max_tokens
  }
  let input_budget = context_window_tokens - reserve
  guard input_budget > 0 else {
    fail("context window is smaller than the reserved output budget")
  }
  if session.estimated_tokens() > input_budget {
    self.compact(
      session,
      api_key,
      base_url,
      model,
      threshold_tokens=input_budget,
      provider~,
    )
  }
  guard session.estimated_tokens() <= input_budget else {
    fail(
      "context budget exceeded after compaction: \{session.estimated_tokens()} > \{input_budget} tokens",
    )
  }
}

///|
pub struct AgentAnswer {
  text : String
  trace : Array[String]
  events : Array[EngineEvent]
}

///|
pub fn AgentAnswer::new(
  text : String,
  trace : Array[String],
  events : Array[EngineEvent],
) -> AgentAnswer {
  { text, trace, events }
}

///|
// Generic LLM tool-calling loop. Sends the request, executes tool calls via
// the Agent's tool registry, respects the tool-call/round budget, and forces
// a plain-text final answer once the budget is exhausted (no tools exposed).
pub async fn Agent::run(
  self : Agent,
  api_key : String,
  base_url : String,
  model : String,
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  provider? : @llm.ProviderKind = @llm.OpenAi,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  let session = self.new_session()
  self.turn(
    session,
    api_key,
    base_url,
    model,
    question,
    on_delta~,
    on_event~,
    provider~,
    context_window_tokens~,
    reserved_output_tokens~,
  )
}

///|
// 单回合：在既有会话上追加用户消息并执行工具循环，把 assistant 回复与
// 工具结果写回会话历史，返回本回合的最终回答。
pub async fn Agent::turn(
  self : Agent,
  session : Session,
  api_key : String,
  base_url : String,
  model : String,
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  on_thinking? : async (String) -> Unit = @llm.ignore_delta,
  provider? : @llm.ProviderKind = @llm.OpenAi,
  context_window_tokens? : Int = 0,
  reserved_output_tokens? : Int = 0,
) -> AgentAnswer {
  session.messages.push(@llm.chat_message("user", question))
  let tools_json = self.tools.map(fn(t) { t.schema.to_json() })
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
      session, api_key, base_url, model, context_window_tokens, reserved_output_tokens,
      provider,
    )
    // 主循环请求不直接流式输出：工具回合里的内容属于思考叙述，
    // 走 on_thinking（前端默认忽略）；最终答案在回合结束后用 on_delta 输出。
    let result = @llm.stream_chat_completion_provider(
      provider,
      api_key,
      base_url,
      model,
      session.messages,
      tools_json,
      max_tokens=self.max_tokens,
      on_delta=@llm.ignore_delta,
      on_reasoning=on_thinking,
      on_retry=async fn(attempt, reason) {
        emit_event(events, on_event, Retrying({ attempt, reason }))
      },
    )
    if result.finish_reason is Some("length") {
      trace.push("[observation] Model hit max_tokens; answer may be truncated")
    }
    if result.tool_calls.is_empty() {
      guard result.content != "" else { fail("model returned an empty answer") }
      on_delta(result.content)
      // A truncated final answer is continued once: feed it back as context
      // and ask the model to complete it with no tools available.
      if result.finish_reason is Some("length") {
        trace.push(
          "[observation] Final answer hit max_tokens; requesting continuation",
        )
        session.messages.push(@llm.chat_message("assistant", result.content))
        session.messages.push(
          @llm.chat_message(
            "user", "(System: continue and complete the answer exactly from where it stopped, keeping the same language and format. No tools are available now: output ONLY the plain Markdown answer, never tool calls or XML.)",
          ),
        )
        self.prepare_context(
          session, api_key, base_url, model, context_window_tokens, reserved_output_tokens,
          provider,
        )
        let cont = @llm.stream_chat_completion_provider(
          provider,
          api_key,
          base_url,
          model,
          session.messages,
          [],
          max_tokens=self.max_tokens,
          on_delta~,
          on_reasoning=on_thinking,
          on_retry=async fn(attempt, reason) {
            emit_event(events, on_event, Retrying({ attempt, reason }))
          },
        )
        let text = if cont.content != "" {
          result.content + "\n" + cont.content
        } else {
          result.content
        }
        session.messages.push(@llm.chat_message("assistant", text))
        emit_event(events, on_event, FinalStarted)
        emit_event(events, on_event, FinalDelta(text))
        trace.push("[final] Model returned an answer (continued)")
        return { text, trace, events }
      }
      session.messages.push(@llm.chat_message("assistant", result.content))
      emit_event(events, on_event, FinalStarted)
      emit_event(events, on_event, FinalDelta(result.content))
      trace.push("[final] Model returned an answer")
      return { text: result.content, trace, events }
    }
    on_thinking(result.content)
    let trimmed = trim_intermediate_content(result.content)
    if trimmed != "" {
      emit_event(
        events,
        on_event,
        ThinkingDelta({ round: step, text: trimmed }),
      )
    }
    session.messages.push(
      @llm.assistant_message_with_tool_calls(trimmed, result.tool_calls),
    )
    let mut call_index = 0
    while call_index < result.tool_calls.length() {
      let call = result.tool_calls[call_index]
      if total_tool_calls >= self.max_tool_calls {
        budget_exhausted = true
        // Keep the message history well-formed: every assistant tool call
        // must have a matching tool result, even if we skip executing it.
        session.messages.push(
          @llm.tool_result_message(
            call.id,
            @tools.error_json("tool call skipped: agent budget exhausted"),
          ),
        )
        call_index += 1
        continue
      }
      // Only delegated research runs concurrently. Local file, shell and
      // publishing tools remain serial so confirmation prompts and workspace
      // mutations keep their deterministic order.
      if call.name == "delegate_task" {
        let delegated_calls : Array[@llm.ChatToolCall] = []
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
        for i = 0; i < delegated_calls.length(); i = i + 1 {
          let delegated = delegated_calls[i]
          let call_result = delegated_results[i]
          let status = tool_result_status(call_result)
          emit_event(
            events,
            on_event,
            ToolFinished({
              round: step,
              call_id: delegated.id,
              name: delegated.name,
              status,
              result: call_result,
            }),
          )
          session.messages.push(
            @llm.tool_result_message(delegated.id, call_result),
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
      let status = tool_result_status(call_result)
      emit_event(
        events,
        on_event,
        ToolFinished({
          round: step,
          call_id: call.id,
          name: call.name,
          status,
          result: call_result,
        }),
      )
      session.messages.push(@llm.tool_result_message(call.id, call_result))
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
      @llm.chat_message(
        "user", "(System: no more tool calls are allowed. Answer the user's question now using the evidence already collected. No tools are available: output ONLY the plain Markdown answer, never tool calls or XML.)",
      ),
    )
    self.prepare_context(
      session, api_key, base_url, model, context_window_tokens, reserved_output_tokens,
      provider,
    )
    // Budget exhausted: force a final answer with no tools exposed.
    let result = @llm.stream_chat_completion_provider(
      provider,
      api_key,
      base_url,
      model,
      session.messages,
      [],
      max_tokens=self.max_tokens,
      on_delta~,
      on_reasoning=on_thinking,
      on_retry=async fn(attempt, reason) {
        emit_event(events, on_event, Retrying({ attempt, reason }))
      },
    )
    if result.content != "" {
      let mut text = result.content
      session.messages.push(@llm.chat_message("assistant", result.content))
      if result.finish_reason is Some("length") {
        // 预算耗尽后的最终回答同样可能超长：续写一次，避免输出截断。
        trace.push(
          "[observation] Final answer hit max_tokens; requesting continuation",
        )
        session.messages.push(
          @llm.chat_message(
            "user", "(System: continue and complete the answer exactly from where it stopped, keeping the same language and format. Output ONLY the plain Markdown answer.)",
          ),
        )
        self.prepare_context(
          session, api_key, base_url, model, context_window_tokens, reserved_output_tokens,
          provider,
        )
        let cont = @llm.stream_chat_completion_provider(
          provider,
          api_key,
          base_url,
          model,
          session.messages,
          [],
          max_tokens=self.max_tokens,
          on_delta~,
          on_reasoning=on_thinking,
          on_retry=async fn(attempt, reason) {
            emit_event(events, on_event, Retrying({ attempt, reason }))
          },
        )
        if cont.content != "" {
          text = text + "\n" + cont.content
          session.messages.push(@llm.chat_message("assistant", cont.content))
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

///|
fn search_result_json(
  modules : Array[@moonsage.ModuleSummary],
  arguments : String,
) -> String raise {
  let query = @tools.argument_string(arguments, "query")
  @moonsage.search_modules(modules, query, limit=5).to_json().stringify()
}

///|
fn ask_system_prompt() -> String {
  (
    #|You are MoonSage, an agent for the MoonBit package ecosystem.
    #|Use search_modules before recommending packages. Translate user intent
    #|into concise English search keywords. Inspect manifests for the most
    #|relevant candidates before making claims about downloads, versions or
    #|build status. Use get_module_index and get_package_docs before making
    #|claims about APIs, functions, types, examples, or backend suitability.
    #|Do not claim a backend is supported unless the evidence explicitly
    #|shows it. Never invent package facts or API usage. Cite each package with
    #|https://mooncakes.io/docs/<owner>/<module>. Answer in the user's language.
    #|Conserve tool calls: never repeat a tool with the same arguments, and
    #|stop calling tools as soon as you have enough evidence to answer. You
    #|have a budget of 12 tool calls total; the final answer must be written
    #|from the evidence already collected.
  )
}

///|
// `ask`/`chat` 共用的 Mooncakes 研究工具集。
pub fn ask_tools(
  modules : Array[@moonsage.ModuleSummary],
) -> Array[@tools.Tool] {
  let mut package_docs_calls = 0
  [
    {
      schema: {
        name: "search_modules",
        description: "Search all Mooncakes modules. Use concise English technical keywords.",
        parameters: @tools.object_schema(
          {
            "query": @tools.string_field(
              "English package search keywords, for example: http client",
            ),
          },
          ["query"],
        ),
      },
      execute: async fn(arguments) {
        let result = search_result_json(modules, arguments) catch {
          e => @tools.error_json(e.to_string())
        }
        @async.sleep(0)
        result
      },
    },
    {
      schema: {
        name: "get_module_manifest",
        description: "Get live metadata for one exact module, including downloads, versions, build status and license.",
        parameters: @tools.object_schema(
          {
            "name": @tools.string_field(
              "Exact owner/module name returned by search_modules",
            ),
          },
          ["name"],
        ),
      },
      execute: async fn(arguments) {
        @mooncakes.fetch_manifest(arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "get_module_index",
        description: "List packages and public symbol names for an exact module version. Call this before requesting package docs.",
        parameters: @tools.object_schema(
          {
            "name": @tools.string_field("Exact owner/module name"),
            "version": @tools.string_field("Exact version from the manifest"),
          },
          ["name", "version"],
        ),
      },
      execute: async fn(arguments) {
        @mooncakes.fetch_module_index(arguments) catch {
          e => @tools.error_json(e.to_string())
        }
      },
    },
    {
      schema: {
        name: "get_package_docs",
        description: "Get compact public API signatures and docstrings for one package returned by get_module_index.",
        parameters: @tools.object_schema(
          {
            "name": @tools.string_field("Exact owner/module name"),
            "version": @tools.string_field("Exact version from the manifest"),
            "package_path": @tools.string_field(
              "Exact full package path returned by get_module_index",
            ),
          },
          ["name", "version", "package_path"],
        ),
      },
      execute: async fn(arguments) {
        package_docs_calls += 1
        if package_docs_calls > 4 {
          @tools.error_json(
            "package docs budget reached; answer using evidence already collected",
          )
        } else {
          @mooncakes.fetch_package_docs(arguments) catch {
            e => @tools.error_json(e.to_string())
          }
        }
      },
    },
  ]
}

///|
// The `ask` agent: research Mooncakes packages and recommend candidates.
pub fn ask_agent(modules : Array[@moonsage.ModuleSummary]) -> Agent {
  {
    system_prompt: ask_system_prompt(),
    tools: ask_tools(modules),
    max_tool_calls: 12,
    max_rounds: 6,
    max_tokens: 1200,
  }
}

///|
fn delegate_task_tool(
  api_key : String,
  base_url : String,
  model : String,
  modules : Array[@moonsage.ModuleSummary],
  provider : @llm.ProviderKind,
  project_instructions : String,
) -> @tools.Tool {
  {
    schema: {
      name: "delegate_task",
      description: "Run one independent, read-only Mooncakes research task in a subagent. Use only for parallelizable investigations; provide a precise objective and return the evidence to combine in your own answer.",
      parameters: @tools.object_schema(
        { "objective": @tools.string_field("A focused research objective") },
        ["objective"],
      ),
    },
    execute: async fn(arguments) {
      let objective = @tools.argument_string(arguments, "objective") catch {
        error => return @tools.error_json(error.to_string())
      }
      let base_agent = ask_agent(modules)
      let subagent : Agent = {
        system_prompt: base_agent.system_prompt +
        project_instructions +
        "\nYou are a delegated research subagent. Answer only the assigned objective with concrete evidence for the parent agent. Do not call delegate_task.",
        tools: base_agent.tools,
        max_tool_calls: 8,
        max_rounds: 4,
        max_tokens: 1000,
      }
      let answer = subagent.run(
        api_key,
        base_url,
        model,
        objective,
        provider~,
        context_window_tokens=32768,
        reserved_output_tokens=1000,
      ) catch {
        error => return @tools.error_json(error.to_string())
      }
      Json::object({ "answer": Json::string(answer.text) }).stringify()
    },
  }
}

///|
fn delegate_task_instruction() -> String {
  (
    #|\nFor independent package research questions, you may use delegate_task.
    #|Delegate only independent, read-only investigations and combine their
    #|evidence yourself. Do not delegate the final answer or the same task
    #|more than once.
  )
}

///|
// Convenience entry point for the `ask` command.
pub async fn run_llm_agent(
  api_key : String,
  base_url : String,
  model : String,
  modules : Array[@moonsage.ModuleSummary],
  question : String,
  on_delta? : async (String) -> Unit = @llm.ignore_delta,
  on_event? : async (EngineEvent) -> Unit = ignore_event,
  provider? : @llm.ProviderKind = @llm.OpenAi,
  extra_tools? : Array[@tools.Tool] = [],
  project_instructions? : String = "",
) -> AgentAnswer {
  let base_agent = ask_agent(modules)
  let agent : Agent = {
    system_prompt: base_agent.system_prompt +
    project_instructions +
    delegate_task_instruction(),
    tools: base_agent.tools +
    [
      delegate_task_tool(
        api_key, base_url, model, modules, provider, project_instructions,
      ),
    ] +
    extra_tools,
    max_tool_calls: base_agent.max_tool_calls,
    max_rounds: base_agent.max_rounds,
    max_tokens: base_agent.max_tokens,
  }
  agent.run(
    api_key,
    base_url,
    model,
    question,
    on_delta~,
    on_event~,
    provider~,
    context_window_tokens=32768,
    reserved_output_tokens=1200,
  )
}
