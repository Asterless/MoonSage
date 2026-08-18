///|
fn batch_secret_values() -> Array[String] {
  let values : Array[String] = []
  for name in ["MOONSAGE_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"] {
    let value = @sys.get_env_var(name).unwrap_or("")
    if value != "" {
      values.push(value)
    }
  }
  values
}

///|
fn batch_number(value : Int) -> Json {
  Json::number(value.to_double())
}

///|
fn batch_strings(values : Array[String]) -> Json {
  Json::array(values.map(fn(value) { Json::string(value) }))
}

///|
async fn output_batch_event(
  event : @batch.BatchEvent,
  stream_json : Bool,
) -> Unit {
  if stream_json {
    write_batch_event(event)
  } else {
    let suffix = if event.item_key == "" { "" } else { " \{event.item_key}" }
    let detail = if event.message == "" { "" } else { ": \{event.message}" }
    @stdio.stdout.write("[\{event.kind}]\{suffix}\{detail}\n")
  }
}

///|
async fn persist_worker_event(
  data_root : String,
  event : @batch.BatchEvent,
  stream_json : Bool,
  secrets : Array[String],
) -> Unit {
  @batch.append_batch_event(data_root, event, secrets~)
  output_batch_event(event, stream_json)
}

///|
fn agent_event_summary(event : @runtime.EngineEvent) -> String {
  match event {
    ToolStarted(tool) => "调用工具 \{tool.name}"
    ToolFinished(tool) =>
      if tool.status == "ok" {
        "\{tool.name} 完成"
      } else {
        "\{tool.name} 返回 \{tool.status}"
      }
    ThinkingDelta(_) => "Agent 思考中…"
    FinalStarted => "开始生成报告"
    FinalDelta(_) => "生成报告中…"
    Retrying(retry) => "第 \{retry.attempt} 次重试"
    Warning(message) => "警告：\{message}"
    Error(message) => "错误：\{message}"
  }
}

///|
async fn emit_agent_event(
  data_root : String,
  batch_id : String,
  item_key : String,
  cycle : Int,
  event : @runtime.EngineEvent,
  stream_json : Bool,
  secrets : Array[String],
) -> Unit {
  // Keep the live activity feed readable: tool boundaries and notable
  // transitions are useful, per-token deltas and thinking streams are not.
  match event {
    ThinkingDelta(_) | FinalDelta(_) => return
    _ => ()
  }
  let batch_event = @batch.BatchEvent::new(
    "agent_event",
    batch_id,
    @async.now(),
    item_key~,
    cycle~,
    message=agent_event_summary(event),
    data=@protocol.event_to_json(event),
  )
  @batch.append_batch_event(data_root, batch_event, secrets~) catch {
    _ => ()
  }
  output_batch_event(batch_event, stream_json)
}

///|
fn batch_state_event(record : @batch.BatchRecord) -> @batch.BatchEvent {
  @batch.BatchEvent::new(
    "batch_state",
    record.id,
    @async.now(),
    cycle=record.cycle,
    message=record.last_error,
    data=Json::object({
      "status": Json::string(record.status.to_string()),
      "pr_count": batch_number(record.pr_count),
    }),
  )
}

///|
async fn fetch_batch_snapshot(retries : Int) -> Array[@types.ModuleSummary] {
  let mut attempt = 0
  for ;; {
    let fetched = Some(@mooncakes.fetch_modules()) catch { _ => None }
    match fetched {
      Some(snapshot) => return snapshot
      None => {
        if attempt >= retries {
          fail("failed to fetch the Mooncakes module snapshot")
        }
        attempt += 1
        @async.sleep(250 * attempt)
      }
    }
  }
}

///|
async fn hydrate_empty_batch(
  data_root : String,
  record : @batch.BatchRecord,
  stream_json : Bool,
  secrets : Array[String],
) -> Unit {
  guard record.items.is_empty() else { return }
  let snapshot = fetch_batch_snapshot(record.config.network_retries)
  let selected = @batch.filter_modules(snapshot, record.config)
  let now = @async.now()
  for selected_module in selected {
    let item = @batch.BatchItem::from_module(selected_module, record.cycle, now)
    item.workspace = @batch.batch_item_workspace(data_root, record.id, item.key)
    record.items.push(item)
  }
  record.last_snapshot_at_ms = now
  record.updated_at_ms = now
  @batch.save_batch(data_root, record, secrets~)
  persist_worker_event(
    data_root,
    @batch.BatchEvent::new(
      "batch_created",
      record.id,
      now,
      cycle=record.cycle,
      data=Json::object({
        "selected": batch_number(selected.length()),
        "snapshot_size": batch_number(snapshot.length()),
      }),
    ),
    stream_json,
    secrets,
  )
  persist_worker_event(
    data_root,
    @batch.BatchEvent::new(
      "snapshot_fetched",
      record.id,
      now,
      cycle=record.cycle,
      data=Json::object({
        "selected": batch_number(selected.length()),
        "snapshot_size": batch_number(snapshot.length()),
      }),
    ),
    stream_json,
    secrets,
  )
  for item in record.items {
    persist_worker_event(
      data_root,
      @batch.BatchEvent::new(
        "item_enqueued",
        record.id,
        now,
        item_key=item.key,
        cycle=record.cycle,
        data=Json::object({
          "repository": Json::string(item.repository),
          "module_names": batch_strings(item.module_names),
          "status": Json::string(item.status.to_string()),
        }),
      ),
      stream_json,
      secrets,
    )
  }
}

///|
async fn refresh_batch_snapshot(
  data_root : String,
  record : @batch.BatchRecord,
  stream_json : Bool,
  secrets : Array[String],
) -> Unit {
  let snapshot = fetch_batch_snapshot(record.config.network_retries)
  let selected = @batch.filter_modules(snapshot, record.config)
  let previous_cycle = record.cycle
  let added = @batch.merge_snapshot(record, selected, @async.now())
  for item in record.items {
    if item.workspace == "" {
      item.workspace = @batch.batch_item_workspace(
        data_root,
        record.id,
        item.key,
      )
    }
  }
  @batch.save_batch(data_root, record, secrets~)
  persist_worker_event(
    data_root,
    @batch.BatchEvent::new(
      "cycle",
      record.id,
      @async.now(),
      cycle=record.cycle,
      data=Json::object({ "enqueued": batch_number(added) }),
    ),
    stream_json,
    secrets,
  )
  persist_worker_event(
    data_root,
    @batch.BatchEvent::new(
      "snapshot_fetched",
      record.id,
      @async.now(),
      cycle=record.cycle,
      data=Json::object({
        "snapshot_size": batch_number(snapshot.length()),
        "selected": batch_number(selected.length()),
        "enqueued": batch_number(added),
      }),
    ),
    stream_json,
    secrets,
  )
  if record.cycle != previous_cycle {
    for item in record.items {
      if item.cycle == record.cycle && item.status is @batch.Queued {
        persist_worker_event(
          data_root,
          @batch.BatchEvent::new(
            "item_enqueued",
            record.id,
            @async.now(),
            item_key=item.key,
            cycle=record.cycle,
            data=Json::object({
              "repository": Json::string(item.repository),
              "module_names": batch_strings(item.module_names),
              "status": Json::string(item.status.to_string()),
            }),
          ),
          stream_json,
          secrets,
        )
      }
    }
  }
}

///|
fn mode1_publish_report(request : @batch.BatchPublishRequest) -> String {
  let validation = request.validation
  let summary = if request.report.trim() == "" {
    "MoonSage applied a verified audit fix."
  } else {
    request.report
  }
  (
    $|## MoonSage batch audit
    $|
    $|Batch: `\{request.batch_id}`
    $|Source revision: `\{request.source_revision}`
    $|Fingerprint: `\{request.fingerprint}`
    $|
    $|### Audit summary
    $|
    $|\{summary}
    $|
    $|### Controller verification
    $|
    $|- `moon check --target native`: \{if validation.check_passed { "passed" } else { "failed" }}
    $|- `moon build --target native`: \{if validation.build_passed { "passed" } else { "failed" }}
    $|- `moon test --target native`: \{if validation.test_passed { "passed" } else { "failed" }}
  )
}

///|
fn retryable_publish_error(message : String) -> Bool {
  let lower = message.to_lower()
  lower.contains("timeout") ||
  lower.contains("timed out") ||
  lower.contains("connection") ||
  lower.contains("resolve host") ||
  lower.contains("network") ||
  lower.contains("http 429") ||
  lower.contains("http 5")
}

///|
async fn publish_mode1_request(
  request : @batch.BatchPublishRequest,
) -> @batch.BatchPublishResult {
  let published = @editing.publish_changes(
    request.project_dir,
    request.owner,
    request.repo,
    @editing.Auto,
    mode1_publish_report(request),
    title="fix: apply MoonSage audit fixes",
    branch=request.branch,
    verified_paths=request.changed_files,
    source_revision=request.source_revision,
    idempotency_key=request.batch_id +
      ":" +
      request.item_key +
      ":" +
      request.fingerprint,
    quiet=true,
    prepare_only=request.prepare_only,
  ) catch {
    error => {
      let message = error.to_string()
      return {
        prepared: false,
        prepared_branch: "",
        prepared_commit: "",
        created: false,
        pr_url: "",
        error: message,
        retryable: retryable_publish_error(message),
      }
    }
  }
  if request.prepare_only {
    match published {
      Some(_) => {
        let (exit, out, _) = @process.collect_output(
          "git",
          ["rev-parse", "HEAD"],
          cwd=request.project_dir,
          no_console_window=true,
        )
        let commit = (out.text() catch { _ => "" }).trim().to_owned()
        if exit == 0 && commit != "" {
          {
            prepared: true,
            prepared_branch: request.branch,
            prepared_commit: commit,
            created: false,
            pr_url: "",
            error: "",
            retryable: false,
          }
        } else {
          {
            prepared: false,
            prepared_branch: "",
            prepared_commit: "",
            created: false,
            pr_url: "",
            error: "publisher prepared a draft but the local commit is missing",
            retryable: false,
          }
        }
      }
      _ =>
        {
          prepared: false,
          prepared_branch: "",
          prepared_commit: "",
          created: false,
          pr_url: "",
          error: "publisher did not prepare a local draft",
          retryable: false,
        }
    }
  } else {
    match published {
      Some(url) if url != "" =>
        {
          prepared: false,
          prepared_branch: "",
          prepared_commit: "",
          created: true,
          pr_url: url,
          error: "",
          retryable: false,
        }
      _ =>
        {
          prepared: false,
          prepared_branch: "",
          prepared_commit: "",
          created: false,
          pr_url: "",
          error: "publisher did not return a pull request URL",
          retryable: false,
        }
    }
  }
}

///|
async fn publish_batch_items(
  data_root : String,
  initial : @batch.BatchRecord,
  stream_json : Bool,
  secrets : Array[String],
) -> @batch.BatchRecord {
  // A paused batch must never keep publishing. The worker's cycle runner has
  // already persisted Paused; the generic publisher also refuses to start
  // when the control file requests a pause.
  if initial.status is @batch.Paused {
    return initial
  }
  let on_event = async fn(event) { output_batch_event(event, stream_json) }
  let control = @batch.load_batch_control(data_root, initial.id)
  let approved = control.approved_items.copy()
  let mut current = initial
  // 阶段 1：本地拟稿。满足自动条件的 item 自动完成分支 + commit（不推送）；
  // 敏感/超限或人工点击“拟稿”的 item 通过 prepare_items 触发。
  for item in current.items {
    if current.status is @batch.Cancelled {
      break
    }
    let manual = control.prepare_items.contains(item.key)
    if !manual && !@batch.can_auto_publish(current, item) {
      continue
    }
    match
      @batch.prepare_batch_item_by_id(
        data_root,
        current.id,
        item.key,
        publish_mode1_request,
        approved=manual,
        on_event~,
        secrets~,
      ) {
      Some(record) => current = record
      None => ()
    }
  }
  // 阶段 2：仅提交人工确认的拟稿（approved_items 且本地 commit 已就绪）。
  for key in approved {
    if current.status is @batch.Cancelled {
      break
    }
    match
      @batch.publish_batch_item_by_id(
        data_root,
        current.id,
        key,
        publish_mode1_request,
        approved=true,
        on_event~,
        secrets~,
      ) {
      Some(record) => current = record
      None => ()
    }
  }
  if !approved.is_empty() {
    let latest = @batch.load_batch_control(data_root, current.id)
    @batch.save_batch_control(data_root, current.id, {
      ..latest,
      approved_items: latest.approved_items.filter(fn(key) {
        !approved.contains(key)
      }),
      updated_at_ms: @async.now(),
    }) catch {
      _ => ()
    }
  }
  current
}

///|
async fn cleanup_finished_batch_workspaces(
  data_root : String,
  record : @batch.BatchRecord,
) -> Unit {
  for item in record.items {
    if item.status
      is (@batch.Created | @batch.NoChanges | @batch.Skipped | @batch.Cancelled) {
      let workspace = @batch.batch_item_workspace(
        data_root,
        record.id,
        item.key,
      ) catch {
        _ => ""
      }
      if workspace != "" {
        @fs.rmdir(workspace, recursive=true) catch {
          _ => ()
        }
      }
    }
  }
}

///|
async fn persist_worker_cancellation(
  data_root : String,
  record : @batch.BatchRecord,
  stream_json : Bool,
  secrets : Array[String],
) -> @batch.BatchRecord {
  @batch.cancel_batch(record, @async.now())
  @batch.save_batch(data_root, record, secrets~)
  cleanup_finished_batch_workspaces(data_root, record)
  persist_worker_event(
    data_root,
    batch_state_event(record),
    stream_json,
    secrets,
  )
  record
}

///|
async fn settle_pending_worker_control(
  data_root : String,
  record : @batch.BatchRecord,
  stream_json : Bool,
  secrets : Array[String],
) -> @batch.BatchRecord? {
  let control = @batch.load_batch_control(data_root, record.id)
  if control.cancel {
    return Some(
      persist_worker_cancellation(data_root, record, stream_json, secrets),
    )
  }
  if control.pause {
    let paused = @batch.recover_batch(record, @async.now())
    paused.status = @batch.Paused
    paused.updated_at_ms = @async.now()
    @batch.save_batch(data_root, paused, secrets~)
    persist_worker_event(
      data_root,
      batch_state_event(paused),
      stream_json,
      secrets,
    )
    return Some(paused)
  }
  None
}

///|
async fn wait_for_watch_interval(
  data_root : String,
  batch_id : String,
  interval_ms : Int,
) -> String {
  let mut remaining = interval_ms
  while remaining > 0 {
    let control = @batch.load_batch_control(data_root, batch_id)
    if control.cancel {
      return "cancel"
    }
    if control.pause {
      return "pause"
    }
    let delay = if remaining > 1000 { 1000 } else { remaining }
    @async.sleep(delay)
    remaining -= delay
  }
  "continue"
}

///|
async fn run_mode1_worker(
  data_root : String,
  batch_id : String,
  stream_json : Bool,
) -> @batch.BatchRecord {
  ignore(@batch.cleanup_batch_retention(data_root, @async.now())) catch {
    _ => ()
  }
  guard @batch.load_batch(data_root, batch_id) is Some(saved) else {
    fail("batch not found: \{batch_id}")
  }
  guard @batch.try_acquire_batch_lock(
    data_root,
    batch_id,
    "mode1-worker-" + @async.now().to_string(),
  ) else {
    fail("batch is already running: \{batch_id}")
  }
  let secrets = batch_secret_values()
  let settled = settle_pending_worker_control(
    data_root, saved, stream_json, secrets,
  ) catch {
    error => {
      @batch.release_batch_lock(data_root, batch_id)
      raise error
    }
  }
  match settled {
    Some(record) => {
      @batch.release_batch_lock(data_root, batch_id)
      return record
    }
    None => ()
  }
  let result = try {
    let api_key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
    guard api_key != "" else {
      fail("set MOONSAGE_API_KEY before starting batch-audit")
    }
    let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
      "https://api.deepseek.com",
    )
    let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
    let provider = @ai.provider_from_string(
      @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
    )
    let on_event = async fn(event) { output_batch_event(event, stream_json) }
    let mut current = @batch.recover_batch(saved, @async.now())
    hydrate_empty_batch(data_root, current, stream_json, secrets)
    for ;; {
      let prior = @batch.completed_fingerprints(@batch.list_batches(data_root))
      current = @batch.run_batch_once(
        data_root,
        current,
        async fn(item) {
          let outcome = @batch.run_mode1_audit_item(
            item,
            current.config,
            api_key,
            base_url,
            model,
            on_event=async fn(event) {
              emit_agent_event(
                data_root,
                current.id,
                item.key,
                current.cycle,
                event,
                stream_json,
                secrets,
              )
            },
            on_stage=async fn(stage) {
              ignore(
                @batch.update_batch_item_stage_by_id(
                  data_root,
                  current.id,
                  item.key,
                  stage,
                  attempts=item.attempts,
                  on_event~,
                  secrets~,
                ),
              )
            },
            should_skip=async fn(owner, repo, revision) {
              if item.force_run || revision == "" {
                false
              } else {
                let fingerprint = @batch.batch_fingerprint(
                  owner,
                  repo,
                  revision,
                  current.config.policy_hash,
                )
                prior.contains(fingerprint)
              }
            },
            provider~,
          )
          outcome
        },
        on_event~,
        secrets~,
      )
      if current.status is @batch.Cancelled {
        cleanup_finished_batch_workspaces(data_root, current)
        break
      }
      current = publish_batch_items(data_root, current, stream_json, secrets)
      cleanup_finished_batch_workspaces(data_root, current)
      if current.status is @batch.Cancelled {
        break
      }
      guard current.config.watch else { break }
      match
        wait_for_watch_interval(
          data_root,
          current.id,
          current.config.interval_ms,
        ) {
        "cancel" => {
          current = persist_worker_cancellation(
            data_root, current, stream_json, secrets,
          )
          break
        }
        "pause" => {
          current.status = @batch.Paused
          current.updated_at_ms = @async.now()
          @batch.save_batch(data_root, current, secrets~)
          persist_worker_event(
            data_root,
            batch_state_event(current),
            stream_json,
            secrets,
          )
          break
        }
        _ =>
          refresh_batch_snapshot(data_root, current, stream_json, secrets) catch {
            error => {
              current.status = @batch.Watching
              current.last_error = error.to_string()
              current.updated_at_ms = @async.now()
              @batch.save_batch(data_root, current, secrets~)
              persist_worker_event(
                data_root,
                batch_state_event(current),
                stream_json,
                secrets,
              )
            }
          }
      }
    }
    current
  } catch {
    error => {
      let failed = @batch.load_batch(data_root, batch_id).unwrap_or(saved)
      let control = @batch.load_batch_control(data_root, batch_id)
      if control.cancel {
        ignore(
          persist_worker_cancellation(data_root, failed, stream_json, secrets),
        ) catch {
          _ => {
            @batch.cancel_batch(failed, @async.now())
            @batch.save_batch(data_root, failed, secrets~) catch {
              _ => ()
            }
            cleanup_finished_batch_workspaces(data_root, failed)
          }
        }
        failed
      } else {
        if !(failed.status is (@batch.Cancelled | @batch.Paused)) {
          failed.status = @batch.Failed
          failed.last_error = error.to_string()
          failed.updated_at_ms = @async.now()
          @batch.save_batch(data_root, failed, secrets~) catch {
            _ => ()
          }
        }
        @batch.release_batch_lock(data_root, batch_id)
        raise error
      }
    }
  }
  @batch.release_batch_lock(data_root, batch_id)
  result
}
