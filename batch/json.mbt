///|
fn json_int(value : Int) -> Json {
  Json::number(value.to_double())
}

///|
fn json_int64(value : Int64) -> Json {
  Json::number(value.to_double())
}

///|
fn json_strings(values : Array[String]) -> Json {
  Json::array(values.map(fn(value) { Json::string(value) }))
}

///|
fn required_string(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(value)) else {
    fail("batch JSON field '\{key}' must be a string")
  }
  value
}

///|
fn optional_string(
  fields : Map[String, Json],
  key : String,
  default : String,
) -> String {
  match fields.get(key) {
    Some(String(value)) => value
    _ => default
  }
}

///|
fn optional_int(fields : Map[String, Json], key : String, default : Int) -> Int {
  match fields.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => default
  }
}

///|
fn optional_int64(
  fields : Map[String, Json],
  key : String,
  default : Int64,
) -> Int64 {
  match fields.get(key) {
    Some(Number(value, ..)) => value.to_int64()
    _ => default
  }
}

///|
fn optional_bool(
  fields : Map[String, Json],
  key : String,
  default : Bool,
) -> Bool {
  match fields.get(key) {
    Some(True) => true
    Some(False) => false
    _ => default
  }
}

///|
fn optional_strings(fields : Map[String, Json], key : String) -> Array[String] {
  let result : Array[String] = []
  match fields.get(key) {
    Some(Array(values)) =>
      for value in values {
        if value is String(text) {
          result.push(text)
        }
      }
    _ => ()
  }
  result
}

///|
pub fn BatchConfig::to_json(self : BatchConfig) -> Json {
  Json::object({
    "includes": json_strings(self.includes),
    "owners": json_strings(self.owners),
    "keywords": json_strings(self.keywords),
    "excludes": json_strings(self.excludes),
    "limit": json_int(self.limit),
    "concurrency": json_int(self.concurrency),
    "max_prs": json_int(self.max_prs),
    "package_timeout_ms": json_int(self.package_timeout_ms),
    "max_calls": json_int(self.max_calls),
    "network_retries": json_int(self.network_retries),
    "watch": Json::boolean(self.watch),
    "interval_ms": json_int(self.interval_ms),
    "policy_hash": Json::string(self.policy_hash),
  })
}

///|
pub fn BatchConfig::from_json(document : Json) -> BatchConfig raise {
  guard document is Object(fields) else {
    fail("batch config must be an object")
  }
  let defaults = default_batch_config()
  let config : BatchConfig = {
    includes: optional_strings(fields, "includes"),
    owners: optional_strings(fields, "owners"),
    keywords: optional_strings(fields, "keywords"),
    excludes: optional_strings(fields, "excludes"),
    limit: optional_int(fields, "limit", defaults.limit),
    concurrency: optional_int(fields, "concurrency", defaults.concurrency),
    max_prs: optional_int(fields, "max_prs", defaults.max_prs),
    package_timeout_ms: optional_int(
      fields,
      "package_timeout_ms",
      defaults.package_timeout_ms,
    ),
    max_calls: optional_int(fields, "max_calls", defaults.max_calls),
    network_retries: optional_int(
      fields,
      "network_retries",
      defaults.network_retries,
    ),
    watch: optional_bool(fields, "watch", defaults.watch),
    interval_ms: optional_int(fields, "interval_ms", defaults.interval_ms),
    policy_hash: optional_string(fields, "policy_hash", defaults.policy_hash),
  }
  validate_batch_config(config)
  config
}

///|
pub fn ValidationSummary::to_json(self : ValidationSummary) -> Json {
  Json::object({
    "check_passed": Json::boolean(self.check_passed),
    "build_passed": Json::boolean(self.build_passed),
    "test_passed": Json::boolean(self.test_passed),
    "check_output": Json::string(self.check_output),
    "build_output": Json::string(self.build_output),
    "test_output": Json::string(self.test_output),
  })
}

///|
pub fn ValidationSummary::from_json(document : Json) -> ValidationSummary raise {
  guard document is Object(fields) else {
    fail("batch validation must be an object")
  }
  {
    check_passed: optional_bool(fields, "check_passed", false),
    build_passed: optional_bool(fields, "build_passed", false),
    test_passed: optional_bool(fields, "test_passed", false),
    check_output: optional_string(fields, "check_output", ""),
    build_output: optional_string(fields, "build_output", ""),
    test_output: optional_string(fields, "test_output", ""),
  }
}

///|
pub fn BatchItem::to_json(self : BatchItem) -> Json {
  Json::object({
    "key": Json::string(self.key),
    "module_names": json_strings(self.module_names),
    "module_version": Json::string(self.module_version),
    "owner": Json::string(self.owner),
    "repo": Json::string(self.repo),
    "repository": Json::string(self.repository),
    "workspace": Json::string(self.workspace),
    "project_dir": Json::string(self.project_dir),
    "source_revision": Json::string(self.source_revision),
    "fingerprint": Json::string(self.fingerprint),
    "status": Json::string(self.status.to_string()),
    "attempts": json_int(self.attempts),
    "cycle": json_int(self.cycle),
    "validation": self.validation.to_json(),
    "report": Json::string(self.report),
    "report_path": Json::string(self.report_path),
    "diff_summary": Json::string(self.diff_summary),
    "changed_files": json_strings(self.changed_files),
    "additions": json_int(self.additions),
    "deletions": json_int(self.deletions),
    "sensitive_changes": Json::boolean(self.sensitive_changes),
    "retryable": Json::boolean(self.retryable),
    "force_run": Json::boolean(self.force_run),
    "pr_url": Json::string(self.pr_url),
    "error": Json::string(self.error),
    "created_at_ms": json_int64(self.created_at_ms),
    "updated_at_ms": json_int64(self.updated_at_ms),
  })
}

///|
pub fn BatchItem::from_json(document : Json) -> BatchItem raise {
  guard document is Object(fields) else { fail("batch item must be an object") }
  let validation = match fields.get("validation") {
    Some(value) => ValidationSummary::from_json(value)
    None => empty_validation_summary()
  }
  {
    key: required_string(fields, "key"),
    module_names: optional_strings(fields, "module_names"),
    module_version: optional_string(fields, "module_version", ""),
    owner: required_string(fields, "owner"),
    repo: required_string(fields, "repo"),
    repository: required_string(fields, "repository"),
    workspace: optional_string(fields, "workspace", ""),
    project_dir: optional_string(fields, "project_dir", ""),
    source_revision: optional_string(fields, "source_revision", ""),
    fingerprint: optional_string(fields, "fingerprint", ""),
    status: BatchItemStatus::from_string(required_string(fields, "status")),
    attempts: optional_int(fields, "attempts", 0),
    cycle: optional_int(fields, "cycle", 1),
    validation,
    report: optional_string(fields, "report", ""),
    report_path: optional_string(fields, "report_path", ""),
    diff_summary: optional_string(fields, "diff_summary", ""),
    changed_files: optional_strings(fields, "changed_files"),
    additions: optional_int(fields, "additions", 0),
    deletions: optional_int(fields, "deletions", 0),
    sensitive_changes: optional_bool(fields, "sensitive_changes", false),
    retryable: optional_bool(fields, "retryable", false),
    force_run: optional_bool(fields, "force_run", false),
    pr_url: optional_string(fields, "pr_url", ""),
    error: optional_string(fields, "error", ""),
    created_at_ms: optional_int64(fields, "created_at_ms", 0L),
    updated_at_ms: optional_int64(fields, "updated_at_ms", 0L),
  }
}

///|
pub fn BatchRecord::status_counts(self : BatchRecord) -> Map[String, Int] {
  let counts : Map[String, Int] = Map([])
  for item in self.items {
    let key = item.status.to_string()
    counts[key] = counts.get(key).unwrap_or(0) + 1
  }
  counts
}

///|
fn counts_to_json(counts : Map[String, Int]) -> Json {
  let fields : Map[String, Json] = Map([])
  for key, value in counts {
    fields[key] = json_int(value)
  }
  Json::object(fields)
}

///|
pub fn BatchRecord::to_json(self : BatchRecord) -> Json {
  Json::object({
    "schema_version": json_int(self.schema_version),
    "id": Json::string(self.id),
    "status": Json::string(self.status.to_string()),
    "config": self.config.to_json(),
    "cycle": json_int(self.cycle),
    "items": Json::array(self.items.map(BatchItem::to_json)),
    "counts": counts_to_json(self.status_counts()),
    "pr_count": json_int(self.pr_count),
    "created_at_ms": json_int64(self.created_at_ms),
    "updated_at_ms": json_int64(self.updated_at_ms),
    "last_snapshot_at_ms": json_int64(self.last_snapshot_at_ms),
    "last_error": Json::string(self.last_error),
  })
}

///|
pub fn BatchRecord::from_json(document : Json) -> BatchRecord raise {
  guard document is Object(fields) else {
    fail("batch record must be an object")
  }
  let schema_version = optional_int(fields, "schema_version", 1)
  guard schema_version == 1 else {
    fail("unsupported batch schema version: \{schema_version}")
  }
  guard fields.get("config") is Some(config_json) else {
    fail("batch JSON field 'config' is required")
  }
  let items : Array[BatchItem] = []
  match fields.get("items") {
    Some(Array(values)) =>
      for value in values {
        items.push(BatchItem::from_json(value))
      }
    _ => fail("batch JSON field 'items' must be an array")
  }
  let id = required_string(fields, "id")
  validate_storage_id(id)
  {
    schema_version,
    id,
    status: BatchStatus::from_string(required_string(fields, "status")),
    config: BatchConfig::from_json(config_json),
    cycle: optional_int(fields, "cycle", 1),
    items,
    pr_count: optional_int(fields, "pr_count", 0),
    created_at_ms: optional_int64(fields, "created_at_ms", 0L),
    updated_at_ms: optional_int64(fields, "updated_at_ms", 0L),
    last_snapshot_at_ms: optional_int64(fields, "last_snapshot_at_ms", 0L),
    last_error: optional_string(fields, "last_error", ""),
  }
}

///|
pub fn BatchEvent::to_json(self : BatchEvent) -> Json {
  Json::object({
    "kind": Json::string(self.kind),
    "batch_id": Json::string(self.batch_id),
    "item_key": Json::string(self.item_key),
    "cycle": json_int(self.cycle),
    "timestamp_ms": json_int64(self.timestamp_ms),
    "message": Json::string(self.message),
    "data": self.data,
  })
}

///|
pub fn BatchEvent::from_json(document : Json) -> BatchEvent raise {
  guard document is Object(fields) else {
    fail("batch event must be an object")
  }
  {
    kind: required_string(fields, "kind"),
    batch_id: required_string(fields, "batch_id"),
    item_key: optional_string(fields, "item_key", ""),
    cycle: optional_int(fields, "cycle", 0),
    timestamp_ms: optional_int64(fields, "timestamp_ms", 0L),
    message: optional_string(fields, "message", ""),
    data: fields.get("data").unwrap_or(Json::object(Map([]))),
  }
}

///|
pub fn BatchControl::to_json(self : BatchControl) -> Json {
  Json::object({
    "pause": Json::boolean(self.pause),
    "cancel": Json::boolean(self.cancel),
    "retry_items": json_strings(self.retry_items),
    "approved_items": json_strings(self.approved_items),
    "updated_at_ms": json_int64(self.updated_at_ms),
  })
}

///|
pub fn BatchControl::from_json(document : Json) -> BatchControl raise {
  guard document is Object(fields) else {
    fail("batch control must be an object")
  }
  {
    pause: optional_bool(fields, "pause", false),
    cancel: optional_bool(fields, "cancel", false),
    retry_items: optional_strings(fields, "retry_items"),
    approved_items: optional_strings(fields, "approved_items"),
    updated_at_ms: optional_int64(fields, "updated_at_ms", 0L),
  }
}

///|
pub fn BatchPublishRequest::to_json(self : BatchPublishRequest) -> Json {
  Json::object({
    "batch_id": Json::string(self.batch_id),
    "item_key": Json::string(self.item_key),
    "owner": Json::string(self.owner),
    "repo": Json::string(self.repo),
    "source_revision": Json::string(self.source_revision),
    "fingerprint": Json::string(self.fingerprint),
    "branch": Json::string(self.branch),
    "workspace": Json::string(self.workspace),
    "project_dir": Json::string(self.project_dir),
    "report": Json::string(self.report),
    "validation": self.validation.to_json(),
    "changed_files": json_strings(self.changed_files),
  })
}
