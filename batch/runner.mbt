///|
pub async fn ignore_batch_event(_event : BatchEvent) -> Unit {
  @async.sleep(0)
}

///|
let batch_stage_mutex : @async.Mutex = Mutex()

///|
fn failed_audit_result(message : String, retryable : Bool) -> BatchAuditResult {
  {
    status: Failed,
    workspace: "",
    project_dir: "",
    source_revision: "",
    report: "",
    report_path: "",
    diff_summary: "",
    changed_files: [],
    additions: 0,
    deletions: 0,
    sensitive_changes: false,
    validation: empty_validation_summary(),
    evidence_conflicts: [],
    needs_review: false,
    error: message,
    retryable,
  }
}

///|
async fn emit_event(
  data_root : String,
  event : BatchEvent,
  on_event : async (BatchEvent) -> Unit,
  secrets : Array[String],
) -> Unit {
  append_batch_event(data_root, event, secrets~) catch {
    _ => ()
  }
  on_event(event) catch {
    _ => ()
  }
}

///|
fn item_state_event(record : BatchRecord, item : BatchItem) -> BatchEvent {
  BatchEvent::new(
    "item_state",
    record.id,
    @async.now(),
    item_key=item.key,
    cycle=record.cycle,
    message=item.error,
    data=Json::object({
      "status": Json::string(item.status.to_string()),
      "attempts": json_int(item.attempts),
      "retryable": Json::boolean(item.retryable),
      "pr_url": Json::string(item.pr_url),
    }),
  )
}

///|
fn batch_state_event(record : BatchRecord) -> BatchEvent {
  BatchEvent::new(
    "batch_state",
    record.id,
    @async.now(),
    cycle=record.cycle,
    message=record.last_error,
    data=Json::object({
      "status": Json::string(record.status.to_string()),
      "counts": counts_to_json(record.status_counts()),
      "pr_count": json_int(record.pr_count),
    }),
  )
}

///|
async fn persist_cancelled_batch(
  data_root : String,
  record : BatchRecord,
  on_event : async (BatchEvent) -> Unit,
  secrets : Array[String],
) -> Unit {
  let now_ms = @async.now()
  cancel_batch(record, now_ms)
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  ignore(cleanup_batch_item_workspaces(data_root, record, now_ms))
  emit_event(data_root, batch_state_event(record), on_event, secrets)
}

///|
async fn cancel_batch_if_requested(
  data_root : String,
  record : BatchRecord,
  on_event : async (BatchEvent) -> Unit,
  secrets : Array[String],
) -> Bool {
  let control = load_batch_control(data_root, record.id)
  guard control.cancel || record.status is Cancelled else { return false }
  persist_cancelled_batch(data_root, record, on_event, secrets)
  true
}

///|
fn publish_pause_requested(
  control : BatchControl,
  record : BatchRecord,
) -> Bool {
  control.pause || record.status is Paused
}

///|
/// Persist one real audit phase reported by the structured executor. Stage
/// callbacks from concurrent items are serialized so each update is merged
/// into the latest record instead of overwriting a sibling item's phase.
pub async fn update_batch_item_stage_by_id(
  data_root : String,
  id : String,
  item_key : String,
  stage : String,
  attempts? : Int = 0,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> Bool {
  guard audit_stage_status(stage) is Some(target) else { return false }
  batch_stage_mutex.acquire()
  let event : BatchEvent? = match load_batch(data_root, id) {
    None => None
    Some(record) =>
      match record.find_item(item_key) {
        None => None
        Some(item) => {
          let previous = item.status
          let previous_attempts = item.attempts
          let advanced = if attempts > item.attempts && target is Fetching {
            item.attempts = attempts
            item.status = Fetching
            item.updated_at_ms = @async.now()
            true
          } else {
            if attempts > item.attempts {
              item.attempts = attempts
            }
            apply_audit_stage(item, stage, @async.now())
          }
          if !advanced ||
            (previous == item.status && previous_attempts == item.attempts) {
            None
          } else {
            record.updated_at_ms = item.updated_at_ms
            let saved = try {
              save_batch(data_root, record, secrets~)
              true
            } catch {
              _ => false
            }
            if saved {
              Some(item_state_event(record, item))
            } else {
              None
            }
          }
        }
      }
  }
  batch_stage_mutex.release()
  match event {
    Some(value) => {
      emit_event(data_root, value, on_event, secrets)
      true
    }
    None => false
  }
}

///|
async fn execute_with_retries(
  item : BatchItem,
  config : BatchConfig,
  execute : async (BatchItem) -> BatchAuditResult,
) -> BatchAuditResult {
  let mut retries = 0
  for ;; {
    item.status = Fetching
    item.updated_at_ms = @async.now()
    let outcome = @async.with_timeout(config.package_timeout_ms, () => {
      execute(item)
    }) catch {
      @async.TimeoutError(_) =>
        return failed_audit_result(
          "package audit timed out after \{config.package_timeout_ms} ms",
          false,
        )
      error => failed_audit_result(error.to_string(), true)
    }
    if !(outcome.status is Failed) ||
      !outcome.retryable ||
      retries >= config.network_retries {
      return outcome
    }
    retries += 1
    item.attempts += 1
  }
}

///|
pub async fn create_batch(
  data_root : String,
  id : String,
  config : BatchConfig,
  snapshot : Array[@types.ModuleSummary],
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  let now = @async.now()
  let selected = filter_modules(snapshot, config)
  let record = BatchRecord::new(id, config, selected, now)
  for item in record.items {
    item.workspace = batch_item_workspace(data_root, id, item.key)
  }
  save_batch(data_root, record, secrets~)
  emit_event(
    data_root,
    BatchEvent::new(
      "batch_created",
      id,
      now,
      cycle=record.cycle,
      data=Json::object({
        "selected": json_int(selected.length()),
        "snapshot_size": json_int(snapshot.length()),
      }),
    ),
    on_event,
    secrets,
  )
  emit_event(
    data_root,
    BatchEvent::new(
      "snapshot_fetched",
      id,
      now,
      cycle=record.cycle,
      data=Json::object({
        "selected": json_int(selected.length()),
        "snapshot_size": json_int(snapshot.length()),
      }),
    ),
    on_event,
    secrets,
  )
  for item in record.items {
    emit_event(
      data_root,
      BatchEvent::new(
        "item_enqueued",
        id,
        now,
        item_key=item.key,
        cycle=record.cycle,
        data=Json::object({
          "repository": Json::string(item.repository),
          "module_names": json_strings(item.module_names),
        }),
      ),
      on_event,
      secrets,
    )
  }
  record
}

///|
/// Run all currently queued repositories. At most `config.concurrency` items
/// execute at once. The injected executor is the only component allowed to
/// access a repository; this core never shells out or talks to GitHub itself.
pub async fn run_batch_once(
  data_root : String,
  record : BatchRecord,
  execute : async (BatchItem) -> BatchAuditResult,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  validate_batch_config(record.config)
  if record.status is Cancelled {
    ignore(cleanup_batch_item_workspaces(data_root, record, @async.now()))
    return record
  }
  if record.status is (Queued | Paused | Watching | Completed | Failed) {
    record.status = Running
    record.updated_at_ms = @async.now()
  }
  save_batch(data_root, record, secrets~)
  emit_event(data_root, batch_state_event(record), on_event, secrets)
  for ;; {
    let control = load_batch_control(data_root, record.id)
    if !control.retry_items.is_empty() {
      for key in control.retry_items {
        retry_batch_item(record, key, @async.now(), force=true) catch {
          _ => ()
        }
      }
      save_batch_control(data_root, record.id, {
        ..control,
        retry_items: [],
        updated_at_ms: @async.now(),
      }) catch {
        _ => ()
      }
    }
    if control.cancel {
      persist_cancelled_batch(data_root, record, on_event, secrets)
      return record
    }
    if control.pause {
      record.status = Paused
      record.updated_at_ms = @async.now()
      save_batch(data_root, record, secrets~)
      emit_event(data_root, batch_state_event(record), on_event, secrets)
      return record
    }
    let claimed = claim_batch_items(record, @async.now())
    if claimed.is_empty() {
      break
    }
    for item in claimed {
      emit_event(data_root, item_state_event(record, item), on_event, secrets)
    }
    save_batch(data_root, record, secrets~)
    let tasks : Array[async () -> (BatchItem, BatchAuditResult)] = claimed.map(fn(
      item,
    ) {
      () => {
        let result = execute_with_retries(item, record.config, execute)
        (item, result)
      }
    })
    let outcomes = @async.all(tasks, max_concurrent=record.config.concurrency)
    let cancellation = load_batch_control(data_root, record.id)
    if cancellation.cancel {
      // A cancellation request wins over results that were already in flight:
      // never let a late model response resurrect an item or make it eligible
      // for publishing after the user asked to stop the batch.
      cancel_batch(record, @async.now())
      for outcome in outcomes {
        let (item, _) = outcome
        item.force_run = false
        emit_event(data_root, item_state_event(record, item), on_event, secrets)
      }
      persist_cancelled_batch(data_root, record, on_event, secrets)
      return record
    } else {
      let completed = completed_fingerprints(list_batches(data_root))
      for outcome in outcomes {
        let (item, result) = outcome
        apply_audit_result(record, item, result, @async.now())
        ignore(apply_idempotency(item, completed, @async.now()))
        item.force_run = false
        emit_event(data_root, item_state_event(record, item), on_event, secrets)
        emit_event(
          data_root,
          BatchEvent::new(
            "validation",
            record.id,
            @async.now(),
            item_key=item.key,
            cycle=record.cycle,
            data=item.validation.to_json(),
          ),
          on_event,
          secrets,
        )
      }
    }
    save_batch(data_root, record, secrets~)
  }
  finalize_batch_cycle(record, @async.now())
  save_batch(data_root, record, secrets~)
  emit_event(data_root, batch_state_event(record), on_event, secrets)
  record
}

///|
pub async fn start_batch(
  data_root : String,
  id : String,
  config : BatchConfig,
  snapshot : Array[@types.ModuleSummary],
  execute : async (BatchItem) -> BatchAuditResult,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  guard try_acquire_batch_lock(
    data_root,
    id,
    "worker-" + @async.now().to_string(),
  ) else {
    fail("batch is already running: \{id}")
  }
  let record = create_batch(
    data_root,
    id,
    config,
    snapshot,
    on_event~,
    secrets~,
  ) catch {
    error => {
      release_batch_lock(data_root, id)
      raise error
    }
  }
  let result = run_batch_once(data_root, record, execute, on_event~, secrets~) catch {
    error => {
      release_batch_lock(data_root, id)
      raise error
    }
  }
  release_batch_lock(data_root, id)
  result
}

///|
pub async fn run_batch_by_id(
  data_root : String,
  id : String,
  execute : async (BatchItem) -> BatchAuditResult,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(saved) else { return None }
  guard try_acquire_batch_lock(
    data_root,
    id,
    "worker-" + @async.now().to_string(),
  ) else {
    saved.last_error = "batch is already running"
    return Some(saved)
  }
  let record = recover_batch(saved, @async.now())
  let result = Some(
    run_batch_once(data_root, record, execute, on_event~, secrets~),
  ) catch {
    error => {
      record.status = Failed
      record.last_error = error.to_string()
      record.updated_at_ms = @async.now()
      save_batch(data_root, record, secrets~) catch {
        _ => ()
      }
      Some(record)
    }
  }
  release_batch_lock(data_root, id)
  result
}

///|
pub async fn get_batch_status(data_root : String, id : String) -> BatchRecord? {
  load_batch(data_root, id)
}

///|
pub async fn pause_batch_by_id(data_root : String, id : String) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  save_batch_control(data_root, id, {
    pause: true,
    cancel: false,
    retry_items: [],
    prepare_items: [],
    approved_items: [],
    updated_at_ms: @async.now(),
  }) catch {
    _ => return Some(record)
  }
  if !(record.status is Cancelled) {
    record.status = Paused
    record.updated_at_ms = @async.now()
    save_batch(data_root, record) catch {
      _ => ()
    }
  }
  Some(record)
}

///|
pub async fn resume_batch_by_id(
  data_root : String,
  id : String,
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  guard !(record.status is Cancelled) else { return Some(record) }
  save_batch_control(data_root, id, {
    pause: false,
    cancel: false,
    retry_items: [],
    prepare_items: [],
    approved_items: [],
    updated_at_ms: @async.now(),
  }) catch {
    _ => return Some(record)
  }
  record.status = Queued
  record.updated_at_ms = @async.now()
  save_batch(data_root, record) catch {
    _ => ()
  }
  Some(record)
}

///|
pub async fn cancel_batch_by_id(
  data_root : String,
  id : String,
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  save_batch_control(data_root, id, {
    pause: false,
    cancel: true,
    retry_items: [],
    prepare_items: [],
    approved_items: [],
    updated_at_ms: @async.now(),
  }) catch {
    _ => ()
  }
  persist_cancelled_batch(data_root, record, ignore_batch_event, [])
  Some(record)
}

///|
pub async fn retry_batch_item_by_id(
  data_root : String,
  id : String,
  item_key : String,
  force? : Bool = false,
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  retry_batch_item(record, item_key, @async.now(), force~) catch {
    _ => return Some(record)
  }
  save_batch(data_root, record) catch {
    _ => ()
  }
  append_batch_event(
    data_root,
    BatchEvent::new(
      "item_state",
      id,
      @async.now(),
      item_key~,
      cycle=record.cycle,
      data=Json::object({ "status": Json::string("queued") }),
    ),
  ) catch {
    _ => ()
  }
  Some(record)
}

///|
pub async fn publish_batch_item_by_id(
  data_root : String,
  id : String,
  item_key : String,
  publish : async (BatchPublishRequest) -> BatchPublishResult,
  approved? : Bool = false,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  // submit 阶段只处理已完成本地拟稿（分支 + commit 就绪）的 item，
  // 未拟稿项必须先经过 prepare，人工确认后才会被推送并创建 PR。
  guard record.find_item(item_key) is Some(item) else { return None }
  guard item.status is VerifiedPendingPublish && item.prepared_commit != "" else {
    return Some(record)
  }
  guard prepare_publish(record, item_key, @async.now(), approved~)
    is Some(request) else {
    return Some(record)
  }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(
    data_root,
    BatchEvent::new(
      "publish",
      id,
      @async.now(),
      item_key~,
      cycle=record.cycle,
      message="publishing",
      data=request.to_json(),
    ),
    on_event,
    secrets,
  )
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  let result = execute_publish_with_retries(request, record.config, publish)
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  apply_publish_result(record, item_key, result, @async.now()) catch {
    _ => return Some(record)
  }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(
    data_root,
    BatchEvent::new(
      "publish",
      id,
      @async.now(),
      item_key~,
      cycle=record.cycle,
      message=result.error,
      data=Json::object({
        "created": Json::boolean(result.created),
        "pr_url": Json::string(result.pr_url),
      }),
    ),
    on_event,
    secrets,
  )
  Some(record)
}

///|
pub async fn prepare_batch_item_by_id(
  data_root : String,
  id : String,
  item_key : String,
  prepare : async (BatchPublishRequest) -> BatchPublishResult,
  approved? : Bool = false,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(record) else { return None }
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  guard record.find_item(item_key) is Some(item) else { return None }
  let eligible = if approved {
    can_prepare(record, item)
  } else {
    can_prepare(record, item) && can_auto_publish(record, item)
  }
  guard eligible else { return Some(record) }
  guard prepare_publish(record, item_key, @async.now(), approved~)
    is Some(request) else {
    return Some(record)
  }
  let request = { ..request, prepare_only: true }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(
    data_root,
    BatchEvent::new(
      "prepare",
      id,
      @async.now(),
      item_key~,
      cycle=record.cycle,
      message="preparing",
      data=request.to_json(),
    ),
    on_event,
    secrets,
  )
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  let result = execute_publish_with_retries(request, record.config, prepare)
  if cancel_batch_if_requested(data_root, record, on_event, secrets) {
    return Some(record)
  }
  if publish_pause_requested(load_batch_control(data_root, id), record) {
    return Some(record)
  }
  apply_prepare_result(record, item_key, result, @async.now()) catch {
    _ => return Some(record)
  }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(
    data_root,
    BatchEvent::new(
      "prepared",
      id,
      @async.now(),
      item_key~,
      cycle=record.cycle,
      message=result.error,
      data=Json::object({
        "prepared": Json::boolean(result.prepared),
        "prepared_branch": Json::string(result.prepared_branch),
        "prepared_commit": Json::string(result.prepared_commit),
        "retryable": Json::boolean(result.retryable),
      }),
    ),
    on_event,
    secrets,
  )
  Some(record)
}

///|
async fn execute_publish_with_retries(
  request : BatchPublishRequest,
  config : BatchConfig,
  publish : async (BatchPublishRequest) -> BatchPublishResult,
) -> BatchPublishResult {
  let mut retries = 0
  for ;; {
    let result = @async.with_timeout(config.package_timeout_ms, () => {
      publish(request)
    }) catch {
      @async.TimeoutError(_) =>
        {
          prepared: false,
          prepared_branch: "",
          prepared_commit: "",
          created: false,
          pr_url: "",
          error: "publish timed out",
          retryable: true,
        }
      error =>
        {
          prepared: false,
          prepared_branch: "",
          prepared_commit: "",
          created: false,
          pr_url: "",
          error: error.to_string(),
          retryable: true,
        }
    }
    if result.created || !result.retryable || retries >= config.network_retries {
      return result
    }
    retries += 1
  }
}

///|
/// 自动拟稿：对满足条件的 item 在本地完成分支 + commit + PR 拟稿（不推送、
/// 不创建远端 PR）。安全项自动拟稿；敏感/超限项需要 key 出现在
/// control.prepare_items（人工点击“拟稿”）中。
pub async fn prepare_ready_batch_items(
  data_root : String,
  record : BatchRecord,
  prepare : async (BatchPublishRequest) -> BatchPublishResult,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  let control = load_batch_control(data_root, record.id)
  if control.cancel || record.status is Cancelled {
    persist_cancelled_batch(data_root, record, on_event, secrets)
    return record
  }
  if publish_pause_requested(control, record) {
    return record
  }
  let mut consumed_prepare = false
  let remaining_prepares = control.prepare_items.copy()
  for item in record.items {
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    let manual = remaining_prepares.contains(item.key)
    guard can_prepare(record, item) &&
      (manual || can_auto_publish(record, item)) else {
      continue
    }
    guard prepare_publish(record, item.key, @async.now(), approved=manual)
      is Some(request) else {
      continue
    }
    if manual {
      remaining_prepares.retain(fn(key) { key != item.key })
      consumed_prepare = true
    }
    let request = { ..request, prepare_only: true }
    save_batch(data_root, record, secrets~) catch {
      _ => ()
    }
    emit_event(
      data_root,
      BatchEvent::new(
        "prepare",
        record.id,
        @async.now(),
        item_key=item.key,
        cycle=record.cycle,
        message="preparing",
        data=request.to_json(),
      ),
      on_event,
      secrets,
    )
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    let result = execute_publish_with_retries(request, record.config, prepare)
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    apply_prepare_result(record, item.key, result, @async.now()) catch {
      _ => ()
    }
    save_batch(data_root, record, secrets~) catch {
      _ => ()
    }
    emit_event(
      data_root,
      BatchEvent::new(
        "prepared",
        record.id,
        @async.now(),
        item_key=item.key,
        cycle=record.cycle,
        message=result.error,
        data=Json::object({
          "prepared": Json::boolean(result.prepared),
          "prepared_branch": Json::string(result.prepared_branch),
          "prepared_commit": Json::string(result.prepared_commit),
          "retryable": Json::boolean(result.retryable),
        }),
      ),
      on_event,
      secrets,
    )
  }
  if consumed_prepare {
    save_batch_control(data_root, record.id, {
      ..control,
      prepare_items: remaining_prepares,
      updated_at_ms: @async.now(),
    }) catch {
      _ => ()
    }
  }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(data_root, batch_state_event(record), on_event, secrets)
  record
}

///|
/// 提交已批准且完成本地拟稿的 item：仅推送并创建远端 PR，绝不自动提交
/// 未出现在 approved_items 中的拟稿。
pub async fn publish_ready_batch_items(
  data_root : String,
  record : BatchRecord,
  publish : async (BatchPublishRequest) -> BatchPublishResult,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  let control = load_batch_control(data_root, record.id)
  if control.cancel || record.status is Cancelled {
    persist_cancelled_batch(data_root, record, on_event, secrets)
    return record
  }
  if publish_pause_requested(control, record) {
    return record
  }
  let mut consumed_approval = false
  let remaining_approvals = control.approved_items.copy()
  for item in record.items {
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    let approved = remaining_approvals.contains(item.key)
    guard approved &&
      item.status is VerifiedPendingPublish &&
      item.prepared_commit != "" else {
      continue
    }
    guard prepare_publish(record, item.key, @async.now(), approved=true)
      is Some(request) else {
      continue
    }
    remaining_approvals.retain(fn(key) { key != item.key })
    consumed_approval = true
    save_batch(data_root, record, secrets~) catch {
      _ => ()
    }
    emit_event(
      data_root,
      BatchEvent::new(
        "publish",
        record.id,
        @async.now(),
        item_key=item.key,
        cycle=record.cycle,
        message="publishing",
        data=request.to_json(),
      ),
      on_event,
      secrets,
    )
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    let result = execute_publish_with_retries(request, record.config, publish)
    if cancel_batch_if_requested(data_root, record, on_event, secrets) {
      return record
    }
    if publish_pause_requested(load_batch_control(data_root, record.id), record) {
      return record
    }
    apply_publish_result(record, item.key, result, @async.now()) catch {
      _ => ()
    }
    save_batch(data_root, record, secrets~) catch {
      _ => ()
    }
    emit_event(
      data_root,
      BatchEvent::new(
        "publish",
        record.id,
        @async.now(),
        item_key=item.key,
        cycle=record.cycle,
        message=result.error,
        data=Json::object({
          "created": Json::boolean(result.created),
          "pr_url": Json::string(result.pr_url),
          "retryable": Json::boolean(result.retryable),
        }),
      ),
      on_event,
      secrets,
    )
  }
  if consumed_approval {
    save_batch_control(data_root, record.id, {
      ..control,
      approved_items: remaining_approvals,
      updated_at_ms: @async.now(),
    }) catch {
      _ => ()
    }
  }
  save_batch(data_root, record, secrets~) catch {
    _ => ()
  }
  emit_event(data_root, batch_state_event(record), on_event, secrets)
  record
}

///|
/// Re-fetch and execute watch cycles until `should_continue` returns false.
/// `max_cycles=0` means no artificial limit; cancellation and pause are still
/// observed through the persisted control file at every cycle boundary.
pub async fn run_batch_watch(
  data_root : String,
  record : BatchRecord,
  fetch_snapshot : async () -> Array[@types.ModuleSummary],
  execute : async (BatchItem) -> BatchAuditResult,
  should_continue : async () -> Bool,
  max_cycles? : Int = 0,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord {
  guard record.config.watch else {
    fail("batch is not configured for watch mode")
  }
  let mut completed_cycles = 0
  let current = run_batch_once(data_root, record, execute, on_event~, secrets~)
  for ;; {
    if max_cycles > 0 && completed_cycles >= max_cycles {
      return current
    }
    guard should_continue() else { return current }
    @async.sleep(current.config.interval_ms)
    let control = load_batch_control(data_root, current.id)
    if control.cancel {
      persist_cancelled_batch(data_root, current, on_event, secrets)
      return current
    }
    if control.pause {
      current.status = Paused
      current.updated_at_ms = @async.now()
      save_batch(data_root, current, secrets~)
      return current
    }
    let snapshot = fetch_snapshot() catch {
      error => {
        current.status = Watching
        current.last_error = error.to_string()
        current.updated_at_ms = @async.now()
        save_batch(data_root, current, secrets~)
        emit_event(data_root, batch_state_event(current), on_event, secrets)
        completed_cycles += 1
        continue
      }
    }
    let selected = filter_modules(snapshot, current.config)
    let added = merge_snapshot(current, selected, @async.now())
    emit_event(
      data_root,
      BatchEvent::new(
        "cycle",
        current.id,
        @async.now(),
        cycle=current.cycle,
        data=Json::object({ "enqueued": json_int(added) }),
      ),
      on_event,
      secrets,
    )
    emit_event(
      data_root,
      BatchEvent::new(
        "snapshot_fetched",
        current.id,
        @async.now(),
        cycle=current.cycle,
        data=Json::object({
          "snapshot_size": json_int(snapshot.length()),
          "selected": json_int(selected.length()),
          "enqueued": json_int(added),
        }),
      ),
      on_event,
      secrets,
    )
    run_batch_once(data_root, current, execute, on_event~, secrets~) |> ignore
    completed_cycles += 1
  }
}

///|
/// Resume a persisted watch batch while holding its advisory worker lock for
/// the full lifetime of the loop. Interrupted item stages are requeued before
/// the first cycle; terminal items retain their persisted state.
pub async fn run_batch_watch_by_id(
  data_root : String,
  id : String,
  fetch_snapshot : async () -> Array[@types.ModuleSummary],
  execute : async (BatchItem) -> BatchAuditResult,
  should_continue : async () -> Bool,
  max_cycles? : Int = 0,
  on_event? : async (BatchEvent) -> Unit = ignore_batch_event,
  secrets? : Array[String] = [],
) -> BatchRecord? {
  guard load_batch(data_root, id) is Some(saved) else { return None }
  guard try_acquire_batch_lock(
    data_root,
    id,
    "watch-worker-" + @async.now().to_string(),
  ) else {
    saved.last_error = "batch is already running"
    return Some(saved)
  }
  let record = recover_batch(saved, @async.now())
  let result = Some(
    run_batch_watch(
      data_root,
      record,
      fetch_snapshot,
      execute,
      should_continue,
      max_cycles~,
      on_event~,
      secrets~,
    ),
  ) catch {
    error => {
      record.status = Failed
      record.last_error = error.to_string()
      record.updated_at_ms = @async.now()
      save_batch(data_root, record, secrets~) catch {
        _ => ()
      }
      Some(record)
    }
  }
  release_batch_lock(data_root, id)
  result
}
