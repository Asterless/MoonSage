///|
/// Lifecycle state for a Mode 1 batch.
pub(all) enum BatchStatus {
  Queued
  Running
  Paused
  Watching
  Completed
  Failed
  Cancelled
} derive(Eq, Debug)

///|
pub fn BatchStatus::to_string(self : BatchStatus) -> String {
  match self {
    Queued => "queued"
    Running => "running"
    Paused => "paused"
    Watching => "watching"
    Completed => "completed"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
pub fn BatchStatus::from_string(value : String) -> BatchStatus raise {
  match value {
    "queued" => Queued
    "running" => Running
    "paused" => Paused
    "watching" => Watching
    "completed" => Completed
    "failed" => Failed
    "cancelled" => Cancelled
    _ => fail("invalid batch status: \{value}")
  }
}

///|
/// Lifecycle state for one repository in a Mode 1 batch.
pub(all) enum BatchItemStatus {
  Queued
  Fetching
  Auditing
  Fixing
  Verifying
  VerifiedPendingPublish
  Publishing
  Created
  NoChanges
  Skipped
  Failed
  Cancelled
} derive(Eq, Debug)

///|
pub fn BatchItemStatus::to_string(self : BatchItemStatus) -> String {
  match self {
    Queued => "queued"
    Fetching => "fetching"
    Auditing => "auditing"
    Fixing => "fixing"
    Verifying => "verifying"
    VerifiedPendingPublish => "verified_pending_publish"
    Publishing => "publishing"
    Created => "created"
    NoChanges => "no_changes"
    Skipped => "skipped"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
pub fn BatchItemStatus::from_string(value : String) -> BatchItemStatus raise {
  match value {
    "queued" => Queued
    "fetching" => Fetching
    "auditing" => Auditing
    "fixing" => Fixing
    "verifying" => Verifying
    "verified_pending_publish" => VerifiedPendingPublish
    "publishing" => Publishing
    "created" => Created
    "no_changes" => NoChanges
    "skipped" => Skipped
    "failed" => Failed
    "cancelled" => Cancelled
    _ => fail("invalid batch item status: \{value}")
  }
}

///|
/// User-supplied selection and execution policy. Repeated values inside one
/// filter category are ORed; the include/owner/keyword categories are ANDed.
pub(all) struct BatchConfig {
  includes : Array[String]
  owners : Array[String]
  keywords : Array[String]
  excludes : Array[String]
  limit : Int
  concurrency : Int
  max_prs : Int
  package_timeout_ms : Int
  max_calls : Int
  network_retries : Int
  watch : Bool
  interval_ms : Int
  policy_hash : String
} derive(Eq, Debug)

///|
pub fn default_batch_config() -> BatchConfig {
  {
    includes: [],
    owners: [],
    keywords: [],
    excludes: [],
    limit: 0,
    concurrency: 2,
    max_prs: 10,
    package_timeout_ms: 20 * 60 * 1000,
    max_calls: 80,
    network_retries: 3,
    watch: false,
    interval_ms: 6 * 60 * 60 * 1000,
    policy_hash: "mode1-v1",
  }
}

///|
pub fn validate_batch_config(config : BatchConfig) -> Unit raise {
  guard config.limit >= 0 else { fail("limit must be at least 0") }
  guard config.concurrency >= 1 && config.concurrency <= 4 else {
    fail("concurrency must be between 1 and 4")
  }
  guard config.max_prs >= 0 else { fail("max_prs must be at least 0") }
  guard config.package_timeout_ms > 0 else {
    fail("package_timeout_ms must be positive")
  }
  guard config.max_calls > 0 else { fail("max_calls must be positive") }
  guard config.network_retries >= 0 && config.network_retries <= 10 else {
    fail("network_retries must be between 0 and 10")
  }
  guard !config.watch || config.interval_ms > 0 else {
    fail("interval_ms must be positive in watch mode")
  }
  guard config.policy_hash != "" else { fail("policy_hash must not be empty") }
}

///|
/// One normalized GitHub repository selected from the Mooncakes snapshot.
pub(all) struct BatchModule {
  key : String
  owner : String
  repo : String
  repository : String
  primary_name : String
  module_names : Array[String]
  mut version : String
} derive(Eq, Debug)

///|
pub(all) struct ValidationSummary {
  check_passed : Bool
  build_passed : Bool
  test_passed : Bool
  check_output : String
  build_output : String
  test_output : String
} derive(Eq, Debug)

///|
pub fn empty_validation_summary() -> ValidationSummary {
  {
    check_passed: false,
    build_passed: false,
    test_passed: false,
    check_output: "",
    build_output: "",
    test_output: "",
  }
}

///|
pub fn ValidationSummary::passed(self : ValidationSummary) -> Bool {
  self.check_passed && self.build_passed && self.test_passed
}

///|
pub(all) struct BatchItem {
  key : String
  mut module_names : Array[String]
  mut module_version : String
  owner : String
  repo : String
  repository : String
  mut workspace : String
  mut project_dir : String
  mut source_revision : String
  mut fingerprint : String
  mut status : BatchItemStatus
  mut attempts : Int
  mut cycle : Int
  mut validation : ValidationSummary
  mut report : String
  mut report_path : String
  mut diff_summary : String
  mut changed_files : Array[String]
  mut additions : Int
  mut deletions : Int
  mut sensitive_changes : Bool
  mut retryable : Bool
  mut force_run : Bool
  mut pr_url : String
  mut error : String
  created_at_ms : Int64
  mut updated_at_ms : Int64
} derive(Eq, Debug)

///|
pub fn BatchItem::from_module(
  item : BatchModule,
  cycle : Int,
  now_ms : Int64,
) -> BatchItem {
  {
    key: item.key,
    module_names: item.module_names.copy(),
    module_version: item.version,
    owner: item.owner,
    repo: item.repo,
    repository: item.repository,
    workspace: "",
    project_dir: "",
    source_revision: "",
    fingerprint: "",
    status: Queued,
    attempts: 0,
    cycle,
    validation: empty_validation_summary(),
    report: "",
    report_path: "",
    diff_summary: "",
    changed_files: [],
    additions: 0,
    deletions: 0,
    sensitive_changes: false,
    retryable: false,
    force_run: false,
    pr_url: "",
    error: "",
    created_at_ms: now_ms,
    updated_at_ms: now_ms,
  }
}

///|
pub(all) struct BatchRecord {
  schema_version : Int
  id : String
  mut status : BatchStatus
  config : BatchConfig
  mut cycle : Int
  items : Array[BatchItem]
  mut pr_count : Int
  created_at_ms : Int64
  mut updated_at_ms : Int64
  mut last_snapshot_at_ms : Int64
  mut last_error : String
} derive(Eq, Debug)

///|
pub fn BatchRecord::new(
  id : String,
  config : BatchConfig,
  modules : Array[BatchModule],
  now_ms : Int64,
) -> BatchRecord raise {
  validate_storage_id(id)
  validate_batch_config(config)
  {
    schema_version: 1,
    id,
    status: Queued,
    config,
    cycle: 1,
    items: modules.map(fn(item) { BatchItem::from_module(item, 1, now_ms) }),
    pr_count: 0,
    created_at_ms: now_ms,
    updated_at_ms: now_ms,
    last_snapshot_at_ms: now_ms,
    last_error: "",
  }
}

///|
pub(all) struct BatchAuditResult {
  status : BatchItemStatus
  workspace : String
  project_dir : String
  source_revision : String
  report : String
  report_path : String
  diff_summary : String
  changed_files : Array[String]
  additions : Int
  deletions : Int
  sensitive_changes : Bool
  validation : ValidationSummary
  evidence_conflicts : Array[String]
  error : String
  retryable : Bool
} derive(Eq, Debug)

///|
pub(all) struct BatchPublishRequest {
  batch_id : String
  item_key : String
  owner : String
  repo : String
  source_revision : String
  fingerprint : String
  branch : String
  workspace : String
  project_dir : String
  report : String
  validation : ValidationSummary
  changed_files : Array[String]
} derive(Eq, Debug)

///|
pub(all) struct BatchPublishResult {
  created : Bool
  pr_url : String
  error : String
  retryable : Bool
} derive(Eq, Debug)

///|
pub(all) struct BatchEvent {
  kind : String
  batch_id : String
  item_key : String
  cycle : Int
  timestamp_ms : Int64
  message : String
  data : Json
} derive(Eq, Debug)

///|
pub fn BatchEvent::new(
  kind : String,
  batch_id : String,
  timestamp_ms : Int64,
  item_key? : String = "",
  cycle? : Int = 0,
  message? : String = "",
  data? : Json = Json::object({}),
) -> BatchEvent {
  { kind, batch_id, item_key, cycle, timestamp_ms, message, data }
}

///|
pub(all) struct BatchControl {
  pause : Bool
  cancel : Bool
  retry_items : Array[String]
  approved_items : Array[String]
  updated_at_ms : Int64
} derive(Eq, Debug)

///|
pub fn empty_batch_control() -> BatchControl {
  {
    pause: false,
    cancel: false,
    retry_items: [],
    approved_items: [],
    updated_at_ms: 0L,
  }
}
