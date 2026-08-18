///|
// The batch audit surface intentionally lives outside the conversation shell.
// It has its own persisted server state, so a reload can resume watching a
// batch without recreating a chat session or a local workspace.
struct BatchConfig {
  watch : Bool
  interval : String
  limit : String
  include_pattern : String
  owner : String
  keyword : String
  exclude : String
  concurrency : String
  max_prs : String
  package_timeout : String
  max_calls : String
} derive(Eq)

///|
struct BatchSummary {
  id : String
  status : String
  mode : String
  total : Int
  completed : Int
  failed : Int
  created_prs : Int
  created_at : String
} derive(Eq)

///|
struct BatchItem {
  key : String
  module_name : String
  repository : String
  status : String
  attempts : Int
  validation : String
  validation_log : String
  diff_summary : String
  pr_url : String
  error : String
  report : String
} derive(Eq)

///|
struct BatchRecord {
  summary : BatchSummary
  cycle : Int
  source_revision : String
  items : Array[BatchItem]
  notice : String
} derive(Eq)

///|
struct BatchModel {
  open : Bool
  loading : Bool
  config : BatchConfig
  batches : Array[BatchSummary]
  detail : BatchRecord
  selected_id : String
  selected_item : String
  poll_scheduled : Bool
  notice : String
  error : String
} derive(Eq)

///|
fn default_batch_config() -> BatchConfig {
  {
    watch: false,
    interval: "6h",
    limit: "0",
    include_pattern: "",
    owner: "",
    keyword: "",
    exclude: "",
    concurrency: "2",
    max_prs: "10",
    package_timeout: "20m",
    max_calls: "80",
  }
}

///|
fn empty_batch_summary() -> BatchSummary {
  {
    id: "",
    status: "queued",
    mode: "batch-audit",
    total: 0,
    completed: 0,
    failed: 0,
    created_prs: 0,
    created_at: "",
  }
}

///|
fn empty_batch_record() -> BatchRecord {
  {
    summary: empty_batch_summary(),
    cycle: 0,
    source_revision: "",
    items: [],
    notice: "",
  }
}

///|
fn upsert_batch_summary(
  batches : Array[BatchSummary],
  summary : BatchSummary,
) -> Array[BatchSummary] {
  let next = Array::copy(batches)
  for index, batch in next {
    if batch.id == summary.id {
      next[index] = summary
      return next
    }
  }
  next.insert(0, summary)
  next
}

///|
fn initial_batch() -> BatchModel {
  {
    open: false,
    loading: false,
    config: default_batch_config(),
    batches: [],
    detail: empty_batch_record(),
    selected_id: "",
    selected_item: "",
    poll_scheduled: false,
    notice: "",
    error: "",
  }
}

///|
fn batch_json_string(fields : Map[String, Json], name : String) -> String {
  json_string_field(fields, name)
}

///|
fn batch_json_string_any(
  fields : Map[String, Json],
  primary : String,
  secondary : String,
) -> String {
  let value = batch_json_string(fields, primary)
  if value == "" {
    batch_json_string(fields, secondary)
  } else {
    value
  }
}

///|
fn batch_json_strings(
  fields : Map[String, Json],
  name : String,
) -> Array[String] {
  guard fields.get(name) is Some(Array(values)) else { return [] }
  let result : Array[String] = []
  for value in values {
    if value is String(text) {
      result.push(text)
    }
  }
  result
}

///|
fn batch_counter(fields : Map[String, Json], name : String) -> Int {
  match fields.get("counters") {
    Some(Object(counters)) => json_int_field(counters, name, 0)
    _ => 0
  }
}

///|
fn batch_validation_summary(fields : Map[String, Json]) -> String {
  match fields.get("validation") {
    Some(String(value)) => value
    Some(Object(validation)) => {
      let result : Array[String] = []
      let add = fn(key, label) {
        match validation.get(key) {
          Some(True) => result.push(label + " 通过")
          Some(False) => result.push(label + " 失败")
          _ => ()
        }
      }
      add("check_passed", "check")
      add("build_passed", "build")
      add("test_passed", "test")
      if result.is_empty() {
        batch_json_string_any(validation, "summary", "status")
      } else {
        result.join(" · ")
      }
    }
    _ => "尚未验证"
  }
}

///|
fn batch_validation_log(fields : Map[String, Json]) -> String {
  guard fields.get("validation") is Some(Object(validation)) else { return "" }
  let parts : Array[String] = []
  let add = fn(key, label) {
    let output = batch_json_string(validation, key)
    if output != "" {
      parts.push(label + "\n" + output)
    }
  }
  add("check_output", "moon check")
  add("build_output", "moon build")
  add("test_output", "moon test")
  parts.join("\n\n")
}

///|
fn batch_json_items(value : Json) -> Array[BatchItem] {
  guard value is Array(values) else { return [] }
  let items : Array[BatchItem] = []
  for value in values {
    guard value is Object(fields) else { continue }
    let key = batch_json_string_any(fields, "key", "item_key")
    let module_names = {
      let values = batch_json_strings(fields, "modules")
      if values.is_empty() {
        batch_json_strings(fields, "module_names")
      } else {
        values
      }
    }
    let module_name = if module_names.is_empty() {
      batch_json_string_any(fields, "module", "name")
    } else {
      module_names.join(", ")
    }
    let repository = batch_json_string_any(fields, "repository", "repo")
    items.push({
      key: if key == "" {
        module_name
      } else {
        key
      },
      module_name,
      repository,
      status: batch_json_string(fields, "status"),
      attempts: json_int_field(fields, "attempts", 0),
      validation: batch_validation_summary(fields),
      validation_log: batch_validation_log(fields),
      diff_summary: batch_json_string_any(fields, "diff_summary", "diff"),
      pr_url: batch_json_string_any(fields, "pr_url", "pull_request_url"),
      error: batch_json_string(fields, "error"),
      report: batch_json_string_any(fields, "report", "report_summary"),
    })
  }
  items
}

///|
fn decode_batch_summary_fields(fields : Map[String, Json]) -> BatchSummary {
  let total = json_int_field(
    fields,
    "total",
    if batch_counter(fields, "total") > 0 {
      batch_counter(fields, "total")
    } else {
      match fields.get("items") {
        Some(Array(items)) => items.length()
        _ => 0
      }
    },
  )
  let completed = json_int_field(
    fields,
    "completed",
    batch_counter(fields, "created") +
    batch_counter(fields, "no_changes") +
    batch_counter(fields, "skipped") +
    batch_counter(fields, "failed") +
    batch_counter(fields, "cancelled") +
    batch_counter(fields, "verified_pending_publish"),
  )
  {
    id: batch_json_string_any(fields, "id", "batch_id"),
    status: batch_json_string(fields, "status"),
    mode: batch_json_string(fields, "mode"),
    total,
    completed,
    failed: json_int_field(
      fields,
      "failed",
      if batch_counter(fields, "failed") > 0 {
        batch_counter(fields, "failed")
      } else {
        json_int_field(fields, "failed_items", 0)
      },
    ),
    created_prs: json_int_field(
      fields,
      "created_prs",
      json_int_field(
        fields,
        "pr_count",
        if batch_counter(fields, "created") > 0 {
          batch_counter(fields, "created")
        } else {
          json_int_field(fields, "prs", 0)
        },
      ),
    ),
    created_at: batch_json_string_any(fields, "created_at", "createdAt"),
  }
}

///|
fn decode_batch_summary(value : Json) -> BatchSummary? {
  guard value is Object(fields) else { return None }
  Some(decode_batch_summary_fields(fields))
}

///|
fn decode_batch_record(value : Json) -> BatchRecord? {
  guard value is Object(root) else { return None }
  let fields = match root.get("batch") {
    Some(Object(batch)) => batch
    _ => root
  }
  let summary = decode_batch_summary_fields(fields)
  let items = match fields.get("items") {
    Some(value) => batch_json_items(value)
    None => []
  }
  Some({
    summary,
    cycle: json_int_field(fields, "cycle", 0),
    source_revision: batch_json_string_any(
      fields, "source_revision", "revision",
    ),
    items,
    notice: batch_json_string(fields, "notice"),
  })
}

///|
fn decode_batch_list(source : String) -> Array[BatchSummary]? {
  let document = @json.parse(source) catch { _ => return None }
  let value = match document {
    Object(fields) =>
      match fields.get("batches") {
        Some(value) => value
        None => document
      }
    _ => document
  }
  guard value is Array(values) else { return None }
  let batches : Array[BatchSummary] = []
  for item in values {
    match decode_batch_summary(item) {
      Some(batch) if batch.id != "" => batches.push(batch)
      _ => continue
    }
  }
  Some(batches)
}

///|
fn decode_batch_document(source : String) -> BatchRecord? {
  let document = @json.parse(source) catch { _ => return None }
  decode_batch_record(document)
}

///|
fn batch_status_class(status : String) -> String {
  match status {
    "created" | "completed" => "batch-status success"
    "failed" | "cancelled" => "batch-status danger"
    "paused" | "verified_pending_publish" => "batch-status warning"
    "running"
    | "watching"
    | "fetching"
    | "auditing"
    | "fixing"
    | "verifying"
    | "publishing" => "batch-status busy"
    _ => "batch-status"
  }
}

///|
fn batch_status_label(status : String) -> String {
  match status {
    "queued" => "排队中"
    "running" => "运行中"
    "watching" => "持续监视"
    "paused" => "已暂停"
    "completed" => "已完成"
    "cancelled" => "已取消"
    "failed" => "失败"
    "fetching" => "抓取中"
    "auditing" => "审计中"
    "fixing" => "修复中"
    "verifying" => "验证中"
    "verified_pending_publish" => "待批准发布"
    "publishing" => "发布中"
    "created" => "PR 已创建"
    "no_changes" => "无变更"
    "skipped" => "已跳过"
    _ => if status == "" { "未知" } else { status }
  }
}

///|
fn batch_action_url(
  batch_id : String,
  action : String,
  item : String,
) -> String {
  let base = "/api/batches/" + encode_workspace_path(batch_id)
  if item == "" {
    base + "/" + action
  } else {
    base + "/items/" + encode_workspace_path(item) + "/" + action
  }
}

///|
extern "js" fn batch_http_request(
  verb : String,
  url : String,
  body : String,
  completed : (String) -> Unit,
  failed : (String) -> Unit,
) -> Unit =
  #| (method, url, body, completed, failed) => {
  #|   void (async () => {
  #|     try {
  #|       const response = await fetch(url, {
  #|         method,
  #|         headers: body ? { "Content-Type": "application/json" } : undefined,
  #|         body: body || undefined,
  #|       });
  #|       const text = await response.text();
  #|       if (!response.ok) {
  #|         let message = text || `HTTP ${response.status}`;
  #|         try { message = JSON.parse(text).error || message; } catch {}
  #|         throw new Error(message);
  #|       }
  #|       completed(text || "{}");
  #|     } catch (error) {
  #|       failed(error instanceof Error ? error.message : String(error));
  #|     }
  #|   })();
  #| }

///|
fn batch_request(
  emit : Emit[Msg],
  verb : String,
  url : String,
  body : String,
  operation : String,
) -> Cmd {
  @cmd.custom_cmd(scheduler => {
    batch_http_request(
      verb,
      url,
      body,
      result => scheduler.add(emit(BatchResponse(operation, result))),
      reason => scheduler.add(emit(BatchFailed(reason))),
    )
  })
}

///|
fn batch_load(emit : Emit[Msg]) -> Cmd {
  batch_request(emit, "GET", "/api/batches", "", "list")
}

///|
fn batch_load_detail(emit : Emit[Msg], id : String) -> Cmd {
  batch_request(
    emit,
    "GET",
    "/api/batches/" + encode_workspace_path(id),
    "",
    "detail",
  )
}

///|
fn batch_json_number(value : String, fallback : Int) -> Json {
  let parsed = @json.parse(value) catch {
    _ => return Json::number(fallback.to_double())
  }
  match parsed {
    Number(number, ..) => Json::number(number)
    _ => Json::number(fallback.to_double())
  }
}

///|
fn batch_json_string_list(value : String) -> Json {
  let values : Array[Json] = []
  for item in value.replace_all(old="\n", new=",").split(",") {
    let normalized = item.trim().to_owned()
    if normalized != "" {
      values.push(Json::string(normalized))
    }
  }
  Json::array(values)
}

///|
fn batch_start(emit : Emit[Msg], config : BatchConfig) -> Cmd {
  let body = Json::object({
    "watch": Json::boolean(config.watch),
    "interval": Json::string(config.interval),
    "limit": batch_json_number(config.limit, 0),
    "include": batch_json_string_list(config.include_pattern),
    "owner": batch_json_string_list(config.owner),
    "keyword": batch_json_string_list(config.keyword),
    "exclude": batch_json_string_list(config.exclude),
    "concurrency": batch_json_number(config.concurrency, 2),
    "max_prs": batch_json_number(config.max_prs, 10),
    "package_timeout": Json::string(config.package_timeout),
    "max_calls": batch_json_number(config.max_calls, 80),
    "mode": Json::string("batch-audit"),
  }).stringify()
  batch_request(emit, "POST", "/api/batches", body, "create")
}

///|
fn batch_refresh_command(emit : Emit[Msg], id : String) -> Cmd {
  @cmd.batch([
    batch_load(emit),
    if id == "" {
      @rabbita.none
    } else {
      batch_load_detail(emit, id)
    },
  ])
}

///|
fn batch_action(
  emit : Emit[Msg],
  action : String,
  id : String,
  item : String,
) -> Cmd {
  batch_request(emit, "POST", batch_action_url(id, action, item), "{}", action)
}

///|
extern "js" fn watch_batch_event_stream(
  id : String,
  changed : () -> Unit,
) -> Unit =
  #| (id, changed) => {
  #|   if (!id || typeof EventSource !== "function") return;
  #|   const active = globalThis.__moonsageBatchEvents;
  #|   if (active && active.id === id && active.source.readyState !== EventSource.CLOSED) return;
  #|   active?.source?.close();
  #|   const source = new EventSource(`/api/batches/${encodeURIComponent(id)}/events`);
  #|   let timer = 0;
  #|   const notify = () => {
  #|     clearTimeout(timer);
  #|     timer = setTimeout(changed, 120);
  #|   };
  #|   source.onmessage = notify;
  #|   source.addEventListener("batch_state", notify);
  #|   source.addEventListener("item_state", notify);
  #|   source.addEventListener("validation", notify);
  #|   source.addEventListener("publish", notify);
  #|   source.onerror = () => {
  #|     // EventSource reconnects automatically. Polling remains active as a
  #|     // fallback, so transient stream failures do not surface as UI errors.
  #|   };
  #|   globalThis.__moonsageBatchEvents = { id, source };
  #| }

///|
extern "js" fn close_batch_event_stream() -> Unit =
  #| () => {
  #|   globalThis.__moonsageBatchEvents?.source?.close();
  #|   globalThis.__moonsageBatchEvents = null;
  #| }

///|
fn watch_batch_events(emit : Emit[Msg], id : String) -> Cmd {
  @cmd.custom_cmd(
    scheduler => {
      watch_batch_event_stream(id, () => scheduler.add(emit(BatchStreamChanged)))
    },
    kind=AfterRender,
  )
}

///|
fn batch_config_value(config : BatchConfig, key : String) -> String {
  match key {
    "interval" => config.interval
    "limit" => config.limit
    "include" => config.include_pattern
    "owner" => config.owner
    "keyword" => config.keyword
    "exclude" => config.exclude
    "concurrency" => config.concurrency
    "max_prs" => config.max_prs
    "package_timeout" => config.package_timeout
    "max_calls" => config.max_calls
    _ => ""
  }
}

///|
fn batch_update(
  model : BatchModel,
  msg : Msg,
  emit : Emit[Msg],
) -> (BatchModel, Cmd)? {
  match msg {
    ToggleBatch =>
      if model.open {
        close_batch_event_stream()
        Some(({ ..model, open: false, poll_scheduled: false }, @rabbita.none))
      } else {
        let next = { ..model, open: true, loading: true, error: "", notice: "" }
        Some((next, batch_load(emit)))
      }
    BatchConfigChanged(key, value) => {
      let config = match key {
        "watch" => { ..model.config, watch: value == "true" }
        "interval" => { ..model.config, interval: value }
        "limit" => { ..model.config, limit: value }
        "include" => { ..model.config, include_pattern: value }
        "owner" => { ..model.config, owner: value }
        "keyword" => { ..model.config, keyword: value }
        "exclude" => { ..model.config, exclude: value }
        "concurrency" => { ..model.config, concurrency: value }
        "max_prs" => { ..model.config, max_prs: value }
        "package_timeout" => { ..model.config, package_timeout: value }
        "max_calls" => { ..model.config, max_calls: value }
        _ => model.config
      }
      Some(({ ..model, config, }, @rabbita.none))
    }
    BatchRefresh =>
      Some(
        (
          { ..model, loading: true, error: "" },
          batch_refresh_command(emit, model.selected_id),
        ),
      )
    BatchSelect(id) => {
      let selected = model.batches.any(batch => batch.id == id)
      if !selected {
        Some((model, @rabbita.none))
      } else {
        Some(
          (
            {
              ..model,
              selected_id: id,
              selected_item: "",
              loading: true,
              error: "",
            },
            batch_load_detail(emit, id),
          ),
        )
      }
    }
    BatchSelectItem(key) =>
      Some(({ ..model, selected_item: key }, @rabbita.none))
    BatchStart =>
      Some(
        (
          { ..model, loading: true, error: "", notice: "" },
          batch_start(emit, model.config),
        ),
      )
    BatchAction(action, id, item) =>
      Some(
        (
          { ..model, loading: true, error: "", notice: "" },
          batch_action(emit, action, id, item),
        ),
      )
    BatchPoll =>
      if model.open && model.selected_id != "" {
        Some(
          (
            { ..model, poll_scheduled: false },
            batch_refresh_command(emit, model.selected_id),
          ),
        )
      } else {
        Some((model, @rabbita.none))
      }
    BatchStreamChanged =>
      if model.open && model.selected_id != "" {
        Some((model, batch_refresh_command(emit, model.selected_id)))
      } else {
        Some((model, @rabbita.none))
      }
    BatchResponse(operation, source) =>
      if operation == "list" {
        match decode_batch_list(source) {
          Some(batches) => {
            let selected_id = if model.selected_id != "" &&
              batches.any(batch => batch.id == model.selected_id) {
              model.selected_id
            } else if batches.length() > 0 {
              batches[0].id
            } else {
              ""
            }
            let detail_command = if selected_id == "" {
              @rabbita.none
            } else {
              batch_load_detail(emit, selected_id)
            }
            Some(
              (
                {
                  ..model,
                  batches,
                  selected_id,
                  loading: selected_id != "",
                  error: "",
                },
                detail_command,
              ),
            )
          }
          None =>
            Some(
              (
                {
                  ..model,
                  loading: false,
                  error: "批次列表格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      } else if operation == "detail" {
        match decode_batch_document(source) {
          Some(detail) => {
            let selected_item = if model.selected_item != "" &&
              detail.items.any(item => item.key == model.selected_item) {
              model.selected_item
            } else if detail.items.length() > 0 {
              detail.items[0].key
            } else {
              ""
            }
            let running = detail.summary.status == "running" ||
              detail.summary.status == "watching" ||
              detail.summary.status == "queued"
            let poll = if running && !model.poll_scheduled {
              @cmd.delay(emit(BatchPoll), 3000)
            } else {
              @rabbita.none
            }
            if !running {
              close_batch_event_stream()
            }
            Some(
              (
                {
                  ..model,
                  detail,
                  batches: upsert_batch_summary(model.batches, detail.summary),
                  selected_item,
                  loading: false,
                  poll_scheduled: running,
                  error: "",
                },
                // The response has already selected the batch; polling is a
                // lightweight fallback when SSE is unavailable.
                @cmd.batch([
                  poll,
                  if running {
                    watch_batch_events(emit, detail.summary.id)
                  } else {
                    @rabbita.none
                  },
                ]),
              ),
            )
          }
          None =>
            Some(
              (
                {
                  ..model,
                  loading: false,
                  error: "批次详情格式无效。",
                },
                @rabbita.none,
              ),
            )
        }
      } else if operation == "create" {
        match decode_batch_document(source) {
          Some(detail) if detail.summary.id != "" =>
            Some(
              (
                {
                  ..model,
                  detail,
                  batches: upsert_batch_summary(model.batches, detail.summary),
                  selected_id: detail.summary.id,
                  selected_item: "",
                  loading: true,
                  notice: "批次已创建，正在启动。",
                  error: "",
                },
                batch_action(emit, "run", detail.summary.id, ""),
              ),
            )
          _ =>
            Some(
              (
                {
                  ..model,
                  loading: true,
                  notice: "批次已创建。",
                  error: "",
                },
                batch_load(emit),
              ),
            )
        }
      } else {
        // Action responses may contain either the updated batch or only an
        // acknowledgement. Always reload both summaries and detail.
        Some(
          (
            { ..model, loading: true, notice: "操作已提交。", error: "" },
            batch_refresh_command(emit, model.selected_id),
          ),
        )
      }
    BatchFailed(reason) =>
      Some(({ ..model, loading: false, error: reason }, @rabbita.none))
    _ => None
  }
}

///|
fn batch_summary_card(
  summary : BatchSummary,
  selected : Bool,
  emit : Emit[Msg],
) -> Html {
  button(
    class=if selected { "batch-row active" } else { "batch-row" },
    type_="button",
    attrs=@html.Attrs::build()
      .aria_current(if selected { "page" } else { "false" })
      .aria_label("选择批次 " + summary.id),
    on_click=emit(BatchSelect(summary.id)),
    [
      div(class="batch-row-main", [
        span(
          class="batch-row-id",
          if summary.id == "" {
            "未命名批次"
          } else {
            summary.id
          },
        ),
        span(
          class=batch_status_class(summary.status),
          batch_status_label(summary.status),
        ),
      ]),
      div(class="batch-row-meta", [
        span("\{summary.completed}/\{summary.total} 包"),
        span("\{summary.created_prs} 个 PR"),
      ]),
    ],
  )
}

///|
fn batch_config_field(
  config : BatchConfig,
  key : String,
  label_text : String,
  placeholder : String,
  emit : Emit[Msg],
) -> Html {
  let numeric = key == "limit" ||
    key == "concurrency" ||
    key == "max_prs" ||
    key == "max_calls"
  label(class="batch-field", [
    span(class="batch-field-label", label_text),
    input(
      class="batch-input",
      input_type=if numeric { Number } else { Text },
      value=batch_config_value(config, key),
      placeholder~,
      inputmode=if numeric { "numeric" } else { "text" },
      attrs=@html.Attrs::build().aria_label(label_text),
      on_input=emit.map(value => BatchConfigChanged(key, value)),
    ),
  ])
}

///|
fn batch_config_view(batch : BatchModel, emit : Emit[Msg]) -> Html {
  let config = batch.config
  section(class="batch-config-panel", [
    div(class="batch-section-heading", [
      div([
        h2("运行配置"),
        p(
          "从 Mooncakes 抓取模块，逐包审计、修复、验证并创建 Ready PR。",
        ),
      ]),
      button(
        class=if config.watch { "batch-switch active" } else { "batch-switch" },
        type_="button",
        attrs=@html.Attrs::build()
          .aria_label("持续监视模式")
          .aria_pressed(if config.watch { "true" } else { "false" }),
        on_click=emit(
          BatchConfigChanged(
            "watch",
            if config.watch {
              "false"
            } else {
              "true"
            },
          ),
        ),
        [
          span(class="batch-switch-track", span(class="batch-switch-thumb", "")),
          span("持续监视"),
        ],
      ),
    ]),
    div(class="batch-fields", [
      batch_config_field(
        config, "include", "包含模块", "moonbitlang/*, user/pkg", emit,
      ),
      batch_config_field(config, "owner", "Owner", "moonbitlang, user", emit),
      batch_config_field(
        config, "keyword", "关键词", "security, parser", emit,
      ),
      batch_config_field(
        config, "exclude", "排除模块", "demo/*, experimental/*", emit,
      ),
      batch_config_field(config, "limit", "包数量上限", "0 = 不限", emit),
      batch_config_field(config, "concurrency", "并发数", "1 - 4", emit),
      batch_config_field(config, "max_prs", "PR 上限", "10", emit),
      batch_config_field(config, "interval", "刷新间隔", "6h", emit),
      batch_config_field(config, "package_timeout", "单包超时", "20m", emit),
      batch_config_field(config, "max_calls", "工具调用上限", "80", emit),
    ]),
    div(class="batch-config-actions", [
      button(
        class="batch-primary-button",
        type_="button",
        disabled=batch.loading,
        on_click=emit(BatchStart),
        [span(if batch.loading { "正在启动…" } else { "启动模式 1" })],
      ),
      p(
        class="batch-policy-note",
        "验证失败、无差异或高风险文件变更不会自动发布。",
      ),
    ]),
  ])
}

///|
fn batch_item_row(item : BatchItem, selected : Bool, emit : Emit[Msg]) -> Html {
  button(
    class=if selected { "batch-item-row active" } else { "batch-item-row" },
    type_="button",
    attrs=@html.Attrs::build()
      .aria_current(if selected { "location" } else { "false" })
      .aria_label("查看 " + item.module_name),
    on_click=emit(BatchSelectItem(item.key)),
    [
      div(class="batch-item-name", [
        span(
          class="batch-item-module",
          if item.module_name == "" {
            item.key
          } else {
            item.module_name
          },
        ),
        span(class="batch-item-repo", item.repository),
      ]),
      span(
        class=batch_status_class(item.status),
        batch_status_label(item.status),
      ),
      span(class="batch-item-attempts", "尝试 \{item.attempts}"),
      if item.pr_url != "" {
        span(class="batch-item-pr", "PR")
      } else {
        span(class="batch-item-pr empty", "")
      },
    ],
  )
}

///|
fn batch_item_detail(
  item : BatchItem,
  batch_id : String,
  emit : Emit[Msg],
) -> Html {
  let can_approve = item.status == "verified_pending_publish"
  let can_retry = item.status == "failed" ||
    item.status == "cancelled" ||
    item.status == "skipped"
  article(class="batch-item-detail", [
    div(class="batch-detail-heading", [
      div([
        h3(if item.module_name == "" { item.key } else { item.module_name }),
        p(class="batch-detail-repo", item.repository),
      ]),
      span(
        class=batch_status_class(item.status),
        batch_status_label(item.status),
      ),
    ]),
    div(class="batch-detail-actions", [
      if can_retry {
        button(
          class="batch-secondary-button",
          type_="button",
          on_click=emit(BatchAction("retry", batch_id, item.key)),
          "重试",
        )
      } else {
        div(class="batch-action-placeholder", "")
      },
      if can_approve {
        button(
          class="batch-primary-button compact",
          type_="button",
          on_click=emit(BatchAction("approve", batch_id, item.key)),
          "批准创建 Ready PR",
        )
      } else {
        div(class="batch-action-placeholder", "")
      },
    ]),
    if item.pr_url != "" {
      div(class="batch-detail-link", [
        span("Pull Request"),
        a(href=item.pr_url, target=Blank, rel="noreferrer", item.pr_url),
      ])
    } else {
      div(class="batch-detail-link empty", "尚未创建 PR")
    },
    div(class="batch-detail-grid", [
      div([small("验证"), p(item.validation)]),
      div([small("变更"), p(item.diff_summary)]),
      div([
        small("错误"),
        p(if item.error == "" { "无" } else { item.error }),
      ]),
      div([small("尝试次数"), p(item.attempts.to_string())]),
    ]),
    if item.report != "" {
      details(class="batch-report", [summary("审计报告"), pre(item.report)])
    } else {
      div(
        class="batch-report-placeholder",
        "审计报告将在任务完成后显示。",
      )
    },
    if item.validation_log != "" {
      details(class="batch-report validation", [
        summary("验证日志"),
        pre(item.validation_log),
      ])
    } else {
      div(
        class="batch-report-placeholder",
        "验证日志将在 check、build 和 test 完成后显示。",
      )
    },
  ])
}

///|
fn find_batch_item(items : Array[BatchItem], key : String) -> BatchItem? {
  for item in items {
    if item.key == key {
      return Some(item)
    }
  }
  None
}

///|
fn batch_view(batch : BatchModel, theme : String, emit : Emit[Msg]) -> Html {
  let summary = batch.detail.summary
  let selected_item = find_batch_item(batch.detail.items, batch.selected_item)
  div(
    class="batch-shell",
    attrs=@html.Attrs::build().data_set("theme", theme),
    [
      header(class="batch-topbar", [
        div(class="batch-brand", [
          span(class="brand-wordmark", "MoonSage"),
          span(class="brand-caption", "MODE 1"),
        ]),
        div(class="batch-title", [
          h1("自动审计"),
          p("Mooncakes → 验证 → Ready PR"),
        ]),
        div(class="batch-topbar-actions", [
          button(
            class="batch-icon-button",
            type_="button",
            title=if theme == "dark" {
              "切换浅色主题"
            } else {
              "切换暗色主题"
            },
            attrs=@html.Attrs::build()
              .aria_label(
                if theme == "dark" {
                  "切换浅色主题"
                } else {
                  "切换暗色主题"
                },
              )
              .aria_pressed(if theme == "dark" { "true" } else { "false" }),
            on_click=emit(ToggleTheme),
            icon(if theme == "dark" { "sun" } else { "moon" }),
          ),
          button(
            class="batch-icon-button",
            type_="button",
            title="刷新批次",
            attrs=@html.Attrs::build().aria_label("刷新批次"),
            on_click=emit(BatchRefresh),
            icon("refresh-cw"),
          ),
          button(
            class="batch-secondary-button",
            type_="button",
            on_click=emit(ToggleBatch),
            "返回工作台",
          ),
        ]),
      ]),
      main_(class="batch-main", [
        batch_config_view(batch, emit),
        section(class="batch-work-area", [
          aside(class="batch-list-panel", [
            div(class="batch-panel-heading", [
              h2("批次"),
              span("\{batch.batches.length()} 个"),
            ]),
            if batch.batches.is_empty() {
              div(class="batch-empty", [
                span("暂无批次"),
                p("启动模式 1 后，任务会出现在这里。"),
              ])
            } else {
              div(
                class="batch-list",
                [
                  for entry in batch.batches => {
                    batch_summary_card(
                      entry,
                      entry.id == batch.selected_id,
                      emit,
                    )
                  }
                ],
              )
            },
          ]),
          section(class="batch-detail-panel", [
            if batch.selected_id == "" {
              div(class="batch-empty batch-empty-detail", [
                h2("选择一个批次"),
                p("查看包状态、验证证据和 PR 链接。"),
              ])
            } else {
              div(class="batch-detail-content", [
                div(class="batch-detail-summary", [
                  div([
                    h2(
                      if summary.id == "" {
                        batch.selected_id
                      } else {
                        summary.id
                      },
                    ),
                    p(summary.created_at),
                  ]),
                  div(class="batch-summary-stats", [
                    span([
                      strong_text("\{summary.completed}"),
                      span(" 已完成"),
                    ]),
                    span([strong_text("\{summary.failed}"), span(" 失败")]),
                    span([
                      strong_text("\{summary.created_prs}"),
                      span(" 个 PR"),
                    ]),
                    span(
                      class=batch_status_class(summary.status),
                      batch_status_label(summary.status),
                    ),
                  ]),
                ]),
                div(class="batch-control-bar", [
                  if summary.status == "running" || summary.status == "watching" {
                    button(
                      class="batch-secondary-button",
                      type_="button",
                      on_click=emit(BatchAction("pause", summary.id, "")),
                      "暂停",
                    )
                  } else if summary.status == "paused" {
                    button(
                      class="batch-primary-button compact",
                      type_="button",
                      on_click=emit(BatchAction("resume", summary.id, "")),
                      "恢复",
                    )
                  } else {
                    div(class="batch-action-placeholder", "")
                  },
                  if summary.status != "completed" &&
                    summary.status != "cancelled" &&
                    summary.status != "failed" {
                    button(
                      class="batch-danger-button",
                      type_="button",
                      on_click=emit(BatchAction("cancel", summary.id, "")),
                      "取消批次",
                    )
                  } else {
                    div(class="batch-action-placeholder", "")
                  },
                  if batch.detail.source_revision != "" {
                    span(
                      class="batch-revision",
                      "源提交 \{batch.detail.source_revision}",
                    )
                  } else {
                    span(class="batch-revision", "")
                  },
                ]),
                div(class="batch-item-workspace", [
                  div(class="batch-item-list", [
                    div(class="batch-panel-heading", [
                      h3("包任务"),
                      span("\{batch.detail.items.length()} 个"),
                    ]),
                    if batch.detail.items.is_empty() {
                      p(class="batch-list-note", "队列正在准备中…")
                    } else {
                      div(
                        [
                          for item in batch.detail.items => {
                            batch_item_row(
                              item,
                              item.key == batch.selected_item,
                              emit,
                            )
                          }
                        ],
                      )
                    },
                  ]),
                  if selected_item is Some(item) {
                    batch_item_detail(item, summary.id, emit)
                  } else {
                    div(
                      class="batch-empty batch-item-empty",
                      "从左侧选择一个包查看详情。",
                    )
                  },
                ]),
              ])
            },
          ]),
        ]),
      ]),
      if batch.error != "" {
        div(
          class="batch-toast error",
          attrs=@html.Attrs::build().role("alert").aria_live("assertive"),
          batch.error,
        )
      } else if batch.notice != "" {
        div(
          class="batch-toast",
          attrs=@html.Attrs::build().role("status").aria_live("polite"),
          batch.notice,
        )
      } else {
        div(class="batch-toast-placeholder", "")
      },
    ],
  )
}

///|
fn strong_text(value : String) -> Html {
  @html.strong(value)
}
