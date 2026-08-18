///|
pub fn BatchRecord::find_item(self : BatchRecord, key : String) -> BatchItem? {
  for item in self.items {
    if item.key == key {
      return Some(item)
    }
  }
  None
}

///|
pub fn batch_can_transition(from : BatchStatus, to : BatchStatus) -> Bool {
  match from {
    Queued => to is (Running | Cancelled)
    Running => to is (Paused | Watching | Completed | Failed | Cancelled)
    Paused => to is (Running | Cancelled)
    Watching => to is (Running | Paused | Completed | Failed | Cancelled)
    Completed => to is (Running | Cancelled)
    Failed => to is (Running | Cancelled)
    Cancelled => false
  }
}

///|
pub fn transition_batch(
  record : BatchRecord,
  status : BatchStatus,
  now_ms : Int64,
) -> Unit raise {
  guard record.status == status || batch_can_transition(record.status, status) else {
    fail(
      "invalid batch transition: \{record.status.to_string()} -> \{status.to_string()}",
    )
  }
  record.status = status
  record.updated_at_ms = now_ms
}

///|
pub fn batch_item_can_transition(
  from : BatchItemStatus,
  to : BatchItemStatus,
) -> Bool {
  match from {
    Queued => to is (Fetching | Auditing | Skipped | Cancelled)
    Fetching => to is (Queued | Auditing | Failed | Skipped | Cancelled)
    Auditing => to is (Fixing | NoChanges | Skipped | Failed | Cancelled)
    Fixing => to is (Verifying | NoChanges | Failed | Cancelled)
    Verifying =>
      to is (VerifiedPendingPublish | NoChanges | Failed | Cancelled)
    VerifiedPendingPublish => to is (Publishing | Queued | Cancelled)
    Publishing => to is (Created | VerifiedPendingPublish | Failed | Cancelled)
    Created => to is Queued
    NoChanges => to is Queued
    Skipped => to is Queued
    Failed => to is Queued
    Cancelled => to is Queued
  }
}

///|
pub fn transition_batch_item(
  item : BatchItem,
  status : BatchItemStatus,
  now_ms : Int64,
) -> Unit raise {
  guard item.status == status || batch_item_can_transition(item.status, status) else {
    fail(
      "invalid batch item transition: \{item.status.to_string()} -> \{status.to_string()}",
    )
  }
  item.status = status
  item.updated_at_ms = now_ms
}

///|
pub fn batch_item_is_active(status : BatchItemStatus) -> Bool {
  status is (Fetching | Auditing | Fixing | Verifying | Publishing)
}

///|
pub fn batch_item_is_settled(status : BatchItemStatus) -> Bool {
  status is (
    VerifiedPendingPublish |
    Created |
    NoChanges |
    Skipped |
    Failed |
    Cancelled
  )
}

///|
pub fn BatchRecord::active_count(self : BatchRecord) -> Int {
  self.items.filter(fn(item) { batch_item_is_active(item.status) }).length()
}

///|
pub fn BatchRecord::queued_count(self : BatchRecord) -> Int {
  self.items.filter(fn(item) { item.status is Queued }).length()
}

///|
pub fn BatchRecord::settled(self : BatchRecord) -> Bool {
  self.items.all(fn(item) { batch_item_is_settled(item.status) })
}

///|
pub fn claim_batch_items(
  record : BatchRecord,
  now_ms : Int64,
) -> Array[BatchItem] {
  if record.status is (Paused | Cancelled | Failed | Completed) {
    return []
  }
  let capacity = record.config.concurrency - record.active_count()
  if capacity <= 0 {
    return []
  }
  let claimed : Array[BatchItem] = []
  for item in record.items {
    if item.status is Queued {
      item.status = Fetching
      item.attempts += 1
      item.updated_at_ms = now_ms
      claimed.push(item)
      if claimed.length() >= capacity {
        break
      }
    }
  }
  claimed
}

///|
pub fn retry_batch_item(
  record : BatchRecord,
  key : String,
  now_ms : Int64,
  force? : Bool = false,
) -> Unit raise {
  guard record.find_item(key) is Some(item) else {
    fail("batch item not found: \{key}")
  }
  let allowed = item.status is Failed ||
    (force && batch_item_is_settled(item.status))
  guard allowed else {
    fail("batch item cannot be retried from \{item.status.to_string()}")
  }
  item.status = Queued
  item.error = ""
  item.retryable = false
  item.force_run = force
  item.pr_url = ""
  item.updated_at_ms = now_ms
  if record.status is (Completed | Failed) {
    record.status = Queued
  }
  record.updated_at_ms = now_ms
}

///|
pub fn cancel_batch(record : BatchRecord, now_ms : Int64) -> Unit {
  record.status = Cancelled
  record.updated_at_ms = now_ms
  for item in record.items {
    if item.status is Queued || batch_item_is_active(item.status) {
      item.status = Cancelled
      item.updated_at_ms = now_ms
    }
  }
}

///|
pub fn recover_batch(record : BatchRecord, now_ms : Int64) -> BatchRecord {
  for item in record.items {
    if batch_item_is_active(item.status) {
      item.status = Queued
      item.retryable = true
      item.error = "recovered after an interrupted worker"
      item.updated_at_ms = now_ms
    }
  }
  if record.status is Running {
    record.status = Queued
  }
  record.updated_at_ms = now_ms
  record
}

///|
fn normalized_changed_path(path : String) -> String {
  path.replace_all(old="\\", new="/").trim(chars="/").to_owned().to_lower()
}

///|
pub fn sensitive_changed_path(path : String) -> Bool {
  let normalized = normalized_changed_path(path)
  let filename = match normalized.split("/").to_array().last() {
    Some(value) => value.to_owned()
    None => normalized
  }
  normalized.has_prefix(".github/workflows/") ||
  normalized == ".gitmodules" ||
  filename == ".gitmodules" ||
  filename == ".env" ||
  filename.has_prefix(".env.") ||
  filename == "credentials" ||
  filename == "credentials.json" ||
  filename == "id_rsa" ||
  filename == "id_ed25519" ||
  filename == ".npmrc" ||
  filename == ".netrc" ||
  filename.has_prefix("secret")
}

///|
pub fn binary_changed_path(path : String) -> Bool {
  let normalized = normalized_changed_path(path)
  [
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".7z", ".exe", ".dll", ".so", ".dylib", ".wasm",
    ".woff", ".woff2", ".ttf", ".otf",
  ].any(fn(extension) { normalized.has_suffix(extension) })
}

///|
pub fn audit_result_has_changes(result : BatchAuditResult) -> Bool {
  !result.changed_files.is_empty() ||
  result.additions > 0 ||
  result.deletions > 0 ||
  !result.diff_summary.trim().is_empty()
}

///|
pub fn apply_audit_result(
  record : BatchRecord,
  item : BatchItem,
  result : BatchAuditResult,
  now_ms : Int64,
) -> Unit {
  item.source_revision = result.source_revision
  if result.workspace != "" {
    item.workspace = result.workspace
  }
  if result.project_dir != "" {
    item.project_dir = result.project_dir
  }
  item.fingerprint = if result.source_revision == "" {
    ""
  } else {
    batch_fingerprint(
      item.owner,
      item.repo,
      result.source_revision,
      record.config.policy_hash,
    )
  }
  item.report = result.report
  item.report_path = result.report_path
  item.diff_summary = result.diff_summary
  item.changed_files = result.changed_files.copy()
  item.additions = result.additions
  item.deletions = result.deletions
  item.validation = result.validation
  item.sensitive_changes = result.sensitive_changes ||
    result.changed_files.any(sensitive_changed_path) ||
    result.changed_files.any(binary_changed_path)
  item.error = result.error
  item.retryable = result.retryable
  item.updated_at_ms = now_ms
  match result.status {
    VerifiedPendingPublish => {
      if !result.evidence_conflicts.is_empty() {
        item.status = Failed
        item.retryable = false
        item.error = "audit evidence conflict: " + result.evidence_conflicts.join("; ")
      } else if !result.validation.passed() {
        item.status = Failed
        item.retryable = false
        item.error = "check, build and test must all pass before publishing"
      } else if !audit_result_has_changes(result) {
        item.status = NoChanges
        item.error = ""
      } else if result.source_revision.trim() == "" {
        item.status = Failed
        item.retryable = false
        item.error = "source revision is required before publishing"
      } else if result.workspace.trim() == "" || result.project_dir.trim() == "" {
        item.status = Failed
        item.retryable = false
        item.error = "verified workspace is required before publishing"
      } else if result.changed_files.is_empty() || result.report.trim() == "" {
        item.status = Failed
        item.retryable = false
        item.error = "audit report and changed file evidence are required before publishing"
      } else {
        item.status = VerifiedPendingPublish
      }
    }
    NoChanges => {
      item.status = NoChanges
      item.error = ""
    }
    Skipped => item.status = Skipped
    Failed => item.status = Failed
    _ => {
      item.status = Failed
      item.retryable = false
      item.error = "audit executor returned an invalid terminal status"
    }
  }
  record.updated_at_ms = now_ms
}

///|
pub fn can_auto_publish(record : BatchRecord, item : BatchItem) -> Bool {
  item.status is VerifiedPendingPublish &&
  item.validation.passed() &&
  publish_context_is_complete(item) &&
  item.error == "" &&
  !item.sensitive_changes &&
  item.additions + item.deletions <= 200 &&
  record.pr_count < record.config.max_prs
}

///|
fn branch_component(value : String, max_chars : Int) -> String {
  let normalized = value.to_lower().replace_all(old=".", new="-")
  if normalized.length() <= max_chars {
    normalized
  } else {
    normalized[:max_chars].to_owned()
  }
}

///|
pub fn batch_branch_name(record : BatchRecord, item : BatchItem) -> String {
  let owner = branch_component(item.owner, 48)
  let repo = branch_component(item.repo, 48)
  let id = branch_component(record.id, 48)
  "moonsage/mode1/\{owner}-\{repo}-\{id}-\{record.cycle}"
}

///|
pub fn prepare_publish(
  record : BatchRecord,
  item_key : String,
  now_ms : Int64,
  approved? : Bool = false,
) -> BatchPublishRequest? {
  guard record.find_item(item_key) is Some(item) else { return None }
  let evidence_ok = item.status is VerifiedPendingPublish &&
    item.validation.passed() &&
    publish_context_is_complete(item) &&
    audit_result_item_has_changes(item) &&
    item.error == ""
  guard evidence_ok && (approved || can_auto_publish(record, item)) else {
    return None
  }
  item.status = Publishing
  item.updated_at_ms = now_ms
  record.updated_at_ms = now_ms
  Some({
    batch_id: record.id,
    item_key: item.key,
    owner: item.owner,
    repo: item.repo,
    source_revision: item.source_revision,
    fingerprint: item.fingerprint,
    branch: batch_branch_name(record, item),
    workspace: item.workspace,
    project_dir: item.project_dir,
    report: item.report,
    validation: item.validation,
    changed_files: item.changed_files.copy(),
  })
}

///|
fn audit_result_item_has_changes(item : BatchItem) -> Bool {
  !item.changed_files.is_empty() ||
  item.additions > 0 ||
  item.deletions > 0 ||
  !item.diff_summary.trim().is_empty()
}

///|
fn publish_context_is_complete(item : BatchItem) -> Bool {
  item.source_revision.trim() != "" &&
  item.fingerprint.trim() != "" &&
  item.workspace.trim() != "" &&
  item.project_dir.trim() != "" &&
  !item.changed_files.is_empty() &&
  item.report.trim() != ""
}

///|
pub fn apply_publish_result(
  record : BatchRecord,
  item_key : String,
  result : BatchPublishResult,
  now_ms : Int64,
) -> Unit raise {
  guard record.find_item(item_key) is Some(item) else {
    fail("batch item not found: \{item_key}")
  }
  guard item.status is Publishing else {
    fail("batch item is not publishing: \{item_key}")
  }
  if result.created && result.pr_url != "" {
    item.status = Created
    item.pr_url = result.pr_url
    item.error = ""
    item.retryable = false
    record.pr_count += 1
  } else if result.retryable {
    item.status = VerifiedPendingPublish
    item.error = result.error
    item.retryable = true
  } else {
    item.status = Failed
    item.error = if result.error == "" { "publish failed" } else { result.error }
    item.retryable = false
  }
  item.updated_at_ms = now_ms
  record.updated_at_ms = now_ms
}

///|
pub fn completed_fingerprints(
  records : Array[BatchRecord],
) -> Map[String, String] {
  let completed : Map[String, String] = Map([])
  for record in records {
    for item in record.items {
      if item.fingerprint != "" && item.status is (Created | NoChanges | Skipped) {
        completed[item.fingerprint] = item.pr_url
      }
    }
  }
  completed
}

///|
pub fn apply_idempotency(
  item : BatchItem,
  completed : Map[String, String],
  now_ms : Int64,
) -> Bool {
  guard item.status is (VerifiedPendingPublish | NoChanges) &&
    !item.force_run &&
    item.fingerprint != "" &&
    completed.contains(item.fingerprint) else {
    return false
  }
  item.status = Skipped
  item.pr_url = completed.get(item.fingerprint).unwrap_or("")
  item.error = "already processed with the same source revision and policy"
  item.updated_at_ms = now_ms
  true
}

///|
pub fn merge_snapshot(
  record : BatchRecord,
  modules : Array[BatchModule],
  now_ms : Int64,
) -> Int {
  record.cycle += 1
  record.pr_count = 0
  record.last_snapshot_at_ms = now_ms
  record.updated_at_ms = now_ms
  let mut enqueued = 0
  for selected in modules {
    match record.find_item(selected.key) {
      None => {
        record.items.push(BatchItem::from_module(selected, record.cycle, now_ms))
        enqueued += 1
      }
      Some(existing) =>
        if existing.module_version != selected.version {
          // Module versions are immutable on Mooncakes, so a changed version is
          // a deterministic signal that the repository needs another audit.
          let replacement = BatchItem::from_module(selected, record.cycle, now_ms)
          existing.module_names = replacement.module_names
          existing.module_version = replacement.module_version
          existing.source_revision = ""
          existing.project_dir = ""
          existing.fingerprint = ""
          existing.status = Queued
          existing.attempts = 0
          existing.cycle = record.cycle
          existing.validation = empty_validation_summary()
          existing.report = ""
          existing.report_path = ""
          existing.diff_summary = ""
          existing.changed_files = []
          existing.additions = 0
          existing.deletions = 0
          existing.sensitive_changes = false
          existing.retryable = false
          existing.force_run = false
          existing.pr_url = ""
          existing.error = ""
          existing.updated_at_ms = now_ms
          enqueued += 1
        }
    }
  }
  enqueued
}

///|
pub fn finalize_batch_cycle(record : BatchRecord, now_ms : Int64) -> Unit {
  if record.status is Cancelled {
    return
  }
  if record.queued_count() == 0 && record.active_count() == 0 {
    record.status = if record.config.watch { Watching } else { Completed }
    record.updated_at_ms = now_ms
  }
}
