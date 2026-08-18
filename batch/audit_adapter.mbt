///|
fn diff_changed_files(diff : String) -> Array[String] {
  let files : Array[String] = []
  for line_view in diff.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("diff --git ") {
      match line.split_once(" b/") {
        Some((_, path)) => {
          let value = path.to_owned().trim(chars="\"").to_owned()
          if value != "" && !files.contains(value) {
            files.push(value)
          }
        }
        None => ()
      }
    }
  }
  files
}

///|
fn diff_line_counts(diff : String) -> (Int, Int) {
  let mut additions = 0
  let mut deletions = 0
  for line_view in diff.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("+") && !line.has_prefix("+++") {
      additions += 1
    } else if line.has_prefix("-") && !line.has_prefix("---") {
      deletions += 1
    }
  }
  (additions, deletions)
}

///|
fn diff_has_unsafe_file_kind(diff : String) -> Bool {
  let lower = diff.to_lower()
  lower.contains("git binary patch") ||
  lower.contains("binary files ") ||
  lower.contains("mode 120000")
}

///|
fn audit_stage_status(stage : String) -> BatchItemStatus? {
  match stage {
    "fetching" => Some(Fetching)
    "auditing" => Some(Auditing)
    "fixing" => Some(Fixing)
    "verifying" => Some(Verifying)
    _ => None
  }
}

///|
fn apply_audit_stage(item : BatchItem, stage : String, now_ms : Int64) -> Bool {
  guard audit_stage_status(stage) is Some(status) else { return false }
  if item.status == status {
    item.updated_at_ms = now_ms
    return true
  }
  guard batch_item_can_transition(item.status, status) else { return false }
  item.status = status
  item.updated_at_ms = now_ms
  true
}

///|
fn retryable_audit_failure(message : String) -> Bool {
  let lower = message.to_lower()
  lower.contains("timeout") ||
  lower.contains("timed out") ||
  lower.contains("connection") ||
  lower.contains("temporar") ||
  lower.contains("http 429") ||
  lower.contains("http 500") ||
  lower.contains("http 502") ||
  lower.contains("http 503") ||
  lower.contains("http 504") ||
  lower.contains("git clone failed")
}

///|
fn audit_validation(
  value : @audit.AuditVerificationSummary,
) -> ValidationSummary {
  {
    check_passed: value.check_passed,
    build_passed: value.build_passed,
    test_passed: value.test_passed,
    check_output: value.check_output,
    build_output: value.build_output,
    test_output: value.test_output,
  }
}

///|
fn audit_diff_summary(
  files : Array[String],
  additions : Int,
  deletions : Int,
) -> String {
  if files.is_empty() && additions == 0 && deletions == 0 {
    ""
  } else {
    "\{files.length()} file(s) changed, +\{additions} -\{deletions}"
  }
}

///|
async fn changed_tree_has_symlink(
  project_dir : String,
  files : Array[String],
) -> Bool {
  for path in files {
    let normalized = path.replace_all(old="\\", new="/")
    if normalized.split("/").any(fn(segment) { segment == ".." }) {
      return true
    }
    let kind = @fs.kind(
      project_dir.trim_end(chars="/\\").to_owned() + "/" + normalized,
      follow_symlink=false,
    ) catch {
      _ => Unknown
    }
    if kind is SymLink {
      return true
    }
  }
  false
}

///|
/// Concrete Mode 1 executor for `run_batch_once` / `run_batch_by_id`.
/// Each attempt gets its own deterministic child directory, preserving a
/// failed attempt while keeping the verified project path available for the
/// separate publisher callback.
pub async fn run_mode1_audit_item(
  item : BatchItem,
  config : BatchConfig,
  api_key : String,
  base_url : String,
  model : String,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  on_stage? : async (String) -> Unit = @audit.ignore_audit_stage,
  provider? : @ai.ProviderKind = OpenAi,
  should_skip? : async (String, String, String) -> Bool = async fn(
    _owner,
    _repo,
    _revision,
  ) {
    false
  },
) -> BatchAuditResult {
  guard !item.module_names.is_empty() else {
    return {
      ..failed_audit_result("batch item has no Mooncakes module name", false),
      workspace: item.workspace,
    }
  }
  guard item.workspace != "" else {
    return failed_audit_result(
      "batch item has no deterministic workspace", false,
    )
  }
  let attempt = if item.attempts < 1 { 1 } else { item.attempts }
  let attempt_workspace = item.workspace + "/attempt-" + attempt.to_string()
  let report_stage = async fn(stage) {
    ignore(apply_audit_stage(item, stage, @async.now()))
    on_stage(stage)
  }
  let package_result = @audit.run_structured_audit_package(
    api_key,
    base_url,
    model,
    item.module_names[0],
    workspace=attempt_workspace,
    max_tool_calls=config.max_calls,
    timeout_ms=config.package_timeout_ms,
    on_event~,
    on_stage=report_stage,
    provider~,
    should_skip~,
  )
  guard package_result.owner.to_lower() == item.owner.to_lower() &&
    package_result.repo.to_lower() == item.repo.to_lower() else {
    return {
      ..failed_audit_result(
        "Mooncakes manifest repository changed from \{item.owner}/\{item.repo}",
        false,
      ),
      workspace: item.workspace,
      project_dir: package_result.project_dir,
      source_revision: package_result.source_revision,
    }
  }
  if package_result.skipped {
    return {
      ..failed_audit_result(
        "already processed with the same source revision and policy", false,
      ),
      status: NoChanges,
      workspace: item.workspace,
      project_dir: package_result.project_dir,
      source_revision: package_result.source_revision,
    }
  }
  let result = package_result.audit
  let files = diff_changed_files(result.diff)
  let (additions, deletions) = diff_line_counts(result.diff)
  let has_symlink = if package_result.project_dir == "" {
    false
  } else {
    changed_tree_has_symlink(package_result.project_dir, files)
  }
  let report_path = if result.report == "" {
    ""
  } else {
    let path = attempt_workspace + "/audit-report.md"
    @fs.write_file(path, result.report, create_mode=CreateOrTruncate) catch {
      _ =>
        return {
          ..failed_audit_result("failed to persist audit report", false),
          workspace: item.workspace,
          project_dir: package_result.project_dir,
          source_revision: package_result.source_revision,
        }
    }
    path
  }
  let validation = audit_validation(result.validation)
  let status : BatchItemStatus = if result.status is Failed {
    Failed
  } else if result.diff.trim().is_empty() && validation.passed() {
    NoChanges
  } else if result.publishable() {
    VerifiedPendingPublish
  } else if result.needs_review &&
    validation.passed() &&
    result.evidence.conflicts.is_empty() {
    // 修复 Agent 自检未完成（或未声明）：验证虽然通过，但结果挂起等待
    // 人工确认，绝不自动拟稿或发布。
    VerifiedPendingPublish
  } else {
    Failed
  }
  let error = if result.error != "" {
    result.error
  } else if status is Failed {
    if !validation.passed() {
      "controller-owned moon check/build/test verification failed"
    } else if !result.evidence.conflicts.is_empty() {
      "audit evidence conflict: " + result.evidence.conflicts.join("; ")
    } else if !result.evidence.verified {
      "agent did not provide successful post-fix verification evidence"
    } else {
      "audit result is not publishable"
    }
  } else {
    ""
  }
  {
    status,
    workspace: item.workspace,
    project_dir: package_result.project_dir,
    source_revision: package_result.source_revision,
    report: result.report,
    report_path,
    diff_summary: audit_diff_summary(files, additions, deletions),
    changed_files: files,
    additions,
    deletions,
    sensitive_changes: has_symlink ||
    diff_has_unsafe_file_kind(result.diff) ||
    (result.diff.trim() != "" && files.is_empty()),
    validation,
    evidence_conflicts: result.evidence.conflicts.copy(),
    needs_review: result.needs_review,
    error,
    retryable: status is Failed && retryable_audit_failure(error),
  }
}
