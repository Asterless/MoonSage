///|
fn batch_secret_values() -> Array[String] {
  let values : Array[String] = []
  for name in [
    "MOONSAGE_API_KEY",
    "GH_TOKEN",
    "GITHUB_TOKEN",
  ] {
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
async fn output_batch_event(event : @batch.BatchEvent, stream_json : Bool) -> Unit {
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
async fn fetch_batch_snapshot(retries : Int) -> Array[@moonsage.ModuleSummary] {
  let mut attempt = 0
  for ;; {
    let fetched = Some(@mooncakes.fetch_modules()) catch {
      _ => None
    }
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
) -> Unit raise {
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
) -> Unit raise {
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
  ) catch {
    error => {
      let message = error.to_string()
      return {
        created: false,
        pr_url: "",
        error: message,
        retryable: retryable_publish_error(message),
      }
    }
  }
  match published {
    Some(url) if url != "" => {
      created: true,
      pr_url: url,
      error: "",
      retryable: false,
    }
    _ => {
      created: false,
      pr_url: "",
      error: "publisher did not return a pull request URL",
      retryable: false,
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
  let on_event = async fn(event) { output_batch_event(event, stream_json) }
  let control = @batch.load_batch_control(data_root, initial.id)
  let approved = control.approved_items.copy()
  let automatic : Array[String] = []
  for item in initial.items {
    if @batch.can_auto_publish(initial, item) {
      automatic.push(item.key)
    }
  }
  let mut current = initial
  for key in approved {
    match @batch.publish_batch_item_by_id(
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
  for key in automatic {
    if current.pr_count >= current.config.max_prs {
      break
    }
    match @batch.publish_batch_item_by_id(
      data_root,
      current.id,
      key,
      publish_mode1_request,
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
async fn cleanup_finished_batch_workspaces(record : @batch.BatchRecord) -> Unit {
  for item in record.items {
    if item.workspace != "" && item.status is (@batch.Created | @batch.NoChanges | @batch.Skipped) {
      @fs.rmdir(item.workspace, recursive=true) catch { _ => () }
    }
  }
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
) -> @batch.BatchRecord raise {
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
  let result = try {
    let api_key = @sys.get_env_var("MOONSAGE_API_KEY").unwrap_or("")
    guard api_key != "" else {
      fail("set MOONSAGE_API_KEY before starting batch-audit")
    }
    let base_url = @sys.get_env_var("MOONSAGE_BASE_URL").unwrap_or(
      "https://api.deepseek.com",
    )
    let model = @sys.get_env_var("MOONSAGE_MODEL").unwrap_or("deepseek-chat")
    let provider = @llm.provider_from_string(
      @sys.get_env_var("MOONSAGE_PROVIDER").unwrap_or(""),
    )
    let secrets = batch_secret_values()
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
            provider~,
          )
          let fingerprint = if outcome.source_revision == "" {
            ""
          } else {
            @batch.batch_fingerprint(
              item.owner,
              item.repo,
              outcome.source_revision,
              current.config.policy_hash,
            )
          }
          if fingerprint != "" && prior.contains(fingerprint) {
            item.pr_url = prior.get(fingerprint).unwrap_or("")
            {
              ..outcome,
              status: @batch.Skipped,
              error: "already processed with the same source revision and policy",
              retryable: false,
            }
          } else {
            outcome
          }
        },
        on_event~,
        secrets~,
      )
      current = publish_batch_items(data_root, current, stream_json, secrets)
      cleanup_finished_batch_workspaces(current)
      guard current.config.watch else { break }
      match wait_for_watch_interval(
        data_root,
        current.id,
        current.config.interval_ms,
      ) {
        "cancel" => {
          @batch.cancel_batch(current, @async.now())
          for item in current.items {
            if item.workspace != "" && item.status is @batch.Cancelled {
              @fs.rmdir(item.workspace, recursive=true) catch { _ => () }
            }
          }
          @batch.save_batch(data_root, current, secrets~)
          persist_worker_event(
            data_root,
            batch_state_event(current),
            stream_json,
            secrets,
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
        _ => {
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
    }
    current
  } catch {
    error => {
      let failed = @batch.load_batch(data_root, batch_id).unwrap_or(saved)
      if !(failed.status is (@batch.Cancelled | @batch.Paused)) {
        failed.status = @batch.Failed
        failed.last_error = error.to_string()
        failed.updated_at_ms = @async.now()
        @batch.save_batch(
          data_root,
          failed,
          secrets=batch_secret_values(),
        ) catch {
          _ => ()
        }
      }
      @batch.release_batch_lock(data_root, batch_id)
      raise error
    }
  }
  @batch.release_batch_lock(data_root, batch_id)
  result
}
