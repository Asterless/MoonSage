///|
fn summary(
  name : String,
  repository : String,
  version? : String = "1.0.0",
  keywords? : Array[String] = [],
) -> @moonsage.ModuleSummary {
  {
    name,
    version,
    license: "MIT",
    repository,
    keywords,
    description: "",
    created_at: "",
  }
}

///|
fn passing_validation() -> ValidationSummary {
  {
    check_passed: true,
    build_passed: true,
    test_passed: true,
    check_output: "ok",
    build_output: "ok",
    test_output: "ok",
  }
}

///|
fn verified_result(
  revision? : String = "abc123",
  path? : String = "src/main.mbt",
) -> BatchAuditResult {
  {
    status: VerifiedPendingPublish,
    workspace: "C:/tmp/moonsage/batch-1/acme--a",
    project_dir: "C:/tmp/moonsage/batch-1/acme--a/attempt-1/repo",
    source_revision: revision,
    report: "fixed",
    report_path: "report.md",
    diff_summary: "1 file changed",
    changed_files: [path],
    additions: 2,
    deletions: 1,
    sensitive_changes: false,
    validation: passing_validation(),
    evidence_conflicts: [],
    error: "",
    retryable: false,
  }
}

///|
test "GitHub repository normalization is strict and deterministic" {
  assert_eq(
    normalize_github_repository(" https://GitHub.com/Owner/Repo.git/ "),
    Some("https://github.com/owner/repo"),
  )
  assert_eq(
    parse_github_repository("https://github.com/owner/repo"),
    Some(("owner", "repo")),
  )
  assert_eq(parse_github_repository("http://github.com/owner/repo"), None)
  assert_eq(
    parse_github_repository("https://github.com/owner/repo/tree/main"),
    None,
  )
  assert_eq(parse_github_repository("https://github.com/owner/.."), None)
  assert_eq(
    parse_github_repository("https://github.com/owner/repo?token=x"),
    None,
  )
}

///|
test "snapshot filtering combines categories and deduplicates repositories" {
  let config = {
    ..default_batch_config(),
    includes: ["acme/*", "other/*"],
    owners: ["acme"],
    keywords: ["parser", "json"],
    excludes: ["*/private-*"],
  }
  let selected = filter_modules([
    summary(
      "acme/parser",
      "https://github.com/Acme/shared.git",
      keywords=["parser"],
    ),
    summary(
      "acme/json",
      "https://github.com/acme/shared",
      keywords=["json"],
    ),
    summary(
      "acme/private-parser",
      "https://github.com/acme/private",
      keywords=["parser"],
    ),
    summary(
      "other/parser",
      "https://github.com/other/parser",
      keywords=["parser"],
    ),
    summary(
      "acme/no-keyword",
      "https://github.com/acme/no-keyword",
      keywords=["http"],
    ),
    summary("acme/not-github", "https://gitlab.com/acme/no"),
  ], config)
  assert_eq(selected.length(), 1)
  assert_eq(selected[0].repository, "https://github.com/acme/shared")
  assert_eq(selected[0].module_names, ["acme/json", "acme/parser"])
}

///|
test "limit applies after stable repository ordering" {
  let config = { ..default_batch_config(), limit: 1 }
  let selected = filter_modules([
    summary("z/mod", "https://github.com/z/z"),
    summary("a/mod", "https://github.com/a/a"),
  ], config)
  assert_eq(selected.length(), 1)
  assert_eq(selected[0].repository, "https://github.com/a/a")
}

///|
test "configuration rejects unsafe execution budgets" {
  let concurrency_error = try {
    validate_batch_config({ ..default_batch_config(), concurrency: 5 })
    false
  } catch {
    _ => true
  }
  assert_true(concurrency_error)
  let timeout_error = try {
    validate_batch_config({ ..default_batch_config(), package_timeout_ms: 0 })
    false
  } catch {
    _ => true
  }
  assert_true(timeout_error)
}

///|
test "record JSON round trips lowercase states and config" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-1", default_batch_config(), selected, 10L)
  record.items[0].status = Failed
  record.items[0].error = "network"
  let encoded = record.to_json().stringify()
  assert_true(encoded.contains("\"status\":\"failed\""))
  let decoded = BatchRecord::from_json(@json.parse(encoded))
  assert_eq(decoded.id, "batch-1")
  assert_true(decoded.items[0].status is Failed)
  assert_eq(decoded.items[0].error, "network")
  assert_eq(decoded.config.concurrency, 2)
}

///|
test "recovery requeues only interrupted item states" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
    summary("acme/b", "https://github.com/acme/b"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-2", default_batch_config(), selected, 1L)
  record.status = Running
  record.items[0].status = Verifying
  record.items[1].status = Created
  let recovered = recover_batch(record, 20L)
  assert_true(recovered.status is Queued)
  assert_true(recovered.items[0].status is Queued)
  assert_true(recovered.items[0].retryable)
  assert_true(recovered.items[1].status is Created)
}

///|
test "verification and change evidence gate publishing" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-3", default_batch_config(), selected, 1L)
  let item = record.items[0]
  item.status = Verifying
  let invalid = { ..verified_result(), validation: empty_validation_summary() }
  apply_audit_result(record, item, invalid, 2L)
  assert_true(item.status is Failed)
  retry_batch_item(record, item.key, 3L)
  item.status = Verifying
  apply_audit_result(record, item, verified_result(revision=""), 4L)
  assert_true(item.status is Failed)
  assert_true(item.error.contains("source revision"))
  retry_batch_item(record, item.key, 5L)
  item.status = Verifying
  apply_audit_result(record, item, {
    ..verified_result(),
    changed_files: [],
  }, 6L)
  assert_true(item.status is Failed)
  assert_true(item.error.contains("changed file evidence"))
  retry_batch_item(record, item.key, 7L)
  item.status = Verifying
  apply_audit_result(record, item, verified_result(), 8L)
  assert_true(item.status is VerifiedPendingPublish)
  assert_true(can_auto_publish(record, item))
  assert_true(prepare_publish(record, item.key, 9L) is Some(_))
}

///|
test "sensitive and oversized changes require explicit approval" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-4", default_batch_config(), selected, 1L)
  let item = record.items[0]
  item.status = Verifying
  let result = {
    ..verified_result(path=".github/workflows/release.yml"),
    additions: 201,
  }
  apply_audit_result(record, item, result, 2L)
  assert_true(item.sensitive_changes)
  assert_true(!can_auto_publish(record, item))
  assert_true(prepare_publish(record, item.key, 3L) is None)
  assert_true(prepare_publish(record, item.key, 4L, approved=true) is Some(_))
}

///|
test "publish result records ready PR and idempotency fingerprint" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-5", default_batch_config(), selected, 1L)
  let item = record.items[0]
  item.status = Verifying
  apply_audit_result(record, item, verified_result(), 2L)
  ignore(prepare_publish(record, item.key, 3L))
  apply_publish_result(record, item.key, {
    created: true,
    pr_url: "https://github.com/acme/a/pull/1",
    error: "",
    retryable: false,
  }, 4L)
  assert_true(item.status is Created)
  assert_eq(record.pr_count, 1)
  let seen = completed_fingerprints([record])
  assert_eq(seen.get(item.fingerprint), Some(item.pr_url))
}

///|
async test "record event control and lock persistence is resumable" {
  let data_root = @fs.tmpdir(prefix="moonsage-batch-test-")
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let record = BatchRecord::new("batch-store", default_batch_config(), selected, 1L)
  save_batch(data_root, record)
  let loaded = load_batch(data_root, "batch-store")
  assert_true(loaded is Some(_))
  assert_eq(loaded.unwrap().items.length(), 1)
  append_batch_event(
    data_root,
    BatchEvent::new(
      "item_state",
      "batch-store",
      2L,
      message="secret-value",
    ),
    secrets=["secret-value"],
  )
  let events = load_batch_events(data_root, "batch-store")
  assert_eq(events.length(), 1)
  assert_eq(events[0].message, "[REDACTED]")
  save_batch_control(data_root, "batch-store", {
    pause: true,
    cancel: false,
    retry_items: ["retry-me"],
    approved_items: ["acme--a"],
    updated_at_ms: 3L,
  })
  let control = load_batch_control(data_root, "batch-store")
  assert_true(control.pause)
  assert_eq(control.retry_items, ["retry-me"])
  assert_eq(control.approved_items, ["acme--a"])
  assert_true(try_acquire_batch_lock(data_root, "batch-store", "worker-1"))
  assert_true(!try_acquire_batch_lock(data_root, "batch-store", "worker-2"))
  release_batch_lock(data_root, "batch-store")
  assert_true(try_acquire_batch_lock(data_root, "batch-store", "worker-3"))
  release_batch_lock(data_root, "batch-store")
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "runner honors concurrency and retry budget without network" {
  let data_root = @fs.tmpdir(prefix="moonsage-runner-test-")
  let config = { ..default_batch_config(), concurrency: 2, network_retries: 3 }
  let snapshot = [
    summary("acme/a", "https://github.com/acme/a"),
    summary("acme/b", "https://github.com/acme/b"),
    summary("acme/c", "https://github.com/acme/c"),
  ]
  let record = create_batch(data_root, "batch-run", config, snapshot)
  let mut active = 0
  let mut peak = 0
  let attempts : Map[String, Int] = Map([])
  let finished = run_batch_once(data_root, record, async fn(item) {
    active += 1
    if active > peak {
      peak = active
    }
    @async.sleep(10)
    let count = attempts.get(item.key).unwrap_or(0) + 1
    attempts[item.key] = count
    active -= 1
    if item.key == "acme--a" && count < 3 {
      failed_audit_result("temporary network error", true)
    } else {
      verified_result(revision="rev-" + item.key)
    }
  })
  assert_true(peak <= 2)
  assert_true(finished.status is Completed)
  assert_true(finished.items.all(fn(item) {
    item.status is VerifiedPendingPublish
  }))
  assert_eq(attempts.get("acme--a"), Some(3))
  assert_eq(finished.find_item("acme--a").unwrap().attempts, 3)
  let persisted = load_batch(data_root, "batch-run").unwrap()
  assert_true(persisted.status is Completed)
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "runner skips completed fingerprints unless retry is forced" {
  let data_root = @fs.tmpdir(prefix="moonsage-idempotency-test-")
  let snapshot = [summary("acme/a", "https://github.com/acme/a")]
  let previous = create_batch(
    data_root,
    "batch-idempotency-previous",
    default_batch_config(),
    snapshot,
  )
  let previous_item = previous.items[0]
  previous_item.status = Verifying
  apply_audit_result(previous, previous_item, {
    ..verified_result(revision="same-revision"),
    workspace: previous_item.workspace,
    project_dir: previous_item.workspace + "/attempt-1/repo",
  }, 2L)
  ignore(prepare_publish(previous, previous_item.key, 3L))
  apply_publish_result(previous, previous_item.key, {
    created: true,
    pr_url: "https://github.com/acme/a/pull/7",
    error: "",
    retryable: false,
  }, 4L)
  save_batch(data_root, previous)
  let current = create_batch(
    data_root,
    "batch-idempotency-current",
    default_batch_config(),
    snapshot,
  )
  let skipped = run_batch_once(data_root, current, (item) => {
    {
      ..verified_result(revision="same-revision"),
      workspace: item.workspace,
      project_dir: item.workspace + "/attempt-1/repo",
    }
  })
  assert_true(skipped.items[0].status is Skipped)
  assert_eq(skipped.items[0].pr_url, "https://github.com/acme/a/pull/7")
  retry_batch_item(skipped, skipped.items[0].key, 5L, force=true)
  let forced = run_batch_once(data_root, skipped, (item) => {
    {
      ..verified_result(revision="same-revision"),
      workspace: item.workspace,
      project_dir: item.workspace + "/attempt-2/repo",
    }
  })
  assert_true(forced.items[0].status is VerifiedPendingPublish)
  assert_true(!forced.items[0].force_run)
  @fs.rmdir(data_root, recursive=true)
}

///|
test "watch snapshot requeues only changed module versions" {
  let config = { ..default_batch_config(), watch: true }
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a", version="1.0.0"),
  ], config)
  let record = BatchRecord::new("batch-watch", config, selected, 1L)
  record.items[0].status = Created
  let unchanged = filter_modules([
    summary("acme/a", "https://github.com/acme/a", version="1.0.0"),
  ], config)
  assert_eq(merge_snapshot(record, unchanged, 2L), 0)
  assert_true(record.items[0].status is Created)
  let changed = filter_modules([
    summary("acme/a", "https://github.com/acme/a", version="1.1.0"),
  ], config)
  assert_eq(merge_snapshot(record, changed, 3L), 1)
  assert_true(record.items[0].status is Queued)
  assert_eq(record.items[0].module_version, "1.1.0")
}

///|
test "watch fingerprint includes every module sharing a repository" {
  let config = { ..default_batch_config(), watch: true }
  let selected = filter_modules([
    summary(
      "acme/parser",
      "https://github.com/acme/shared",
      version="1.0.0",
    ),
    summary(
      "acme/runtime",
      "https://github.com/acme/shared",
      version="2.0.0",
    ),
  ], config)
  assert_eq(
    selected[0].version,
    "acme/parser@1.0.0|acme/runtime@2.0.0",
  )
  let record = BatchRecord::new("batch-shared-watch", config, selected, 1L)
  record.items[0].status = Created
  let changed = filter_modules([
    summary(
      "acme/runtime",
      "https://github.com/acme/shared",
      version="2.1.0",
    ),
    summary(
      "acme/parser",
      "https://github.com/acme/shared",
      version="1.0.0",
    ),
  ], config)
  assert_eq(merge_snapshot(record, changed, 2L), 1)
  assert_true(record.items[0].status is Queued)
  assert_eq(
    record.items[0].module_version,
    "acme/parser@1.0.0|acme/runtime@2.1.0",
  )
}

///|
test "audit adapter parses diff evidence and retryable failures" {
  let diff =
    #|diff --git a/src/main.mbt b/src/main.mbt
    #|index 1111111..2222222 100644
    #|--- a/src/main.mbt
    #|+++ b/src/main.mbt
    #|@@ -1,2 +1,2 @@
    #|-let old = 1
    #|+let current = 2
    #| unchanged
    #|diff --git a/README.md b/README.md
    #|new file mode 100644
    #|--- /dev/null
    #|+++ b/README.md
    #|@@ -0,0 +1 @@
    #|+ready
    #|
  assert_eq(diff_changed_files(diff), ["src/main.mbt", "README.md"])
  assert_eq(diff_line_counts(diff), (2, 1))
  assert_true(retryable_audit_failure("HTTP 503 from Mooncakes"))
  assert_true(retryable_audit_failure("git clone failed: connection reset"))
  assert_true(!retryable_audit_failure("moon test failed"))
  assert_true(diff_has_unsafe_file_kind("new file mode 120000\n"))
  assert_true(diff_has_unsafe_file_kind("GIT binary patch\n"))
  assert_true(!diff_has_unsafe_file_kind(diff))
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let item = BatchItem::from_module(selected[0], 1, 1L)
  item.status = Fetching
  assert_true(apply_audit_stage(item, "fetching", 2L))
  assert_true(apply_audit_stage(item, "auditing", 3L))
  assert_true(apply_audit_stage(item, "fixing", 4L))
  assert_true(apply_audit_stage(item, "verifying", 5L))
  assert_true(!apply_audit_stage(item, "fetching", 6L))
  assert_true(!apply_audit_stage(item, "unknown", 7L))
  assert_true(item.status is Verifying)
}

///|
async test "mode1 adapter rejects invalid items before network access" {
  let selected = filter_modules([
    summary("acme/a", "https://github.com/acme/a"),
  ], default_batch_config())
  let item = BatchItem::from_module(selected[0], 1, 1L)
  item.module_names = []
  item.workspace = "unused"
  let missing_module = run_mode1_audit_item(
    item,
    default_batch_config(),
    "",
    "",
    "",
  )
  assert_true(missing_module.status is Failed)
  assert_eq(missing_module.error, "batch item has no Mooncakes module name")
  item.module_names = ["acme/a"]
  item.workspace = ""
  let missing_workspace = run_mode1_audit_item(
    item,
    default_batch_config(),
    "",
    "",
    "",
  )
  assert_true(missing_workspace.status is Failed)
  assert_eq(missing_workspace.error, "batch item has no deterministic workspace")
}

///|
async test "create batch persists deterministic item workspaces" {
  let data_root = @fs.tmpdir(prefix="moonsage-workspace-test-")
  let record = create_batch(
    data_root,
    "batch-workspaces",
    default_batch_config(),
    [
      summary("acme/a", "https://github.com/acme/a"),
      summary("acme/b", "https://github.com/acme/b"),
    ],
  )
  for item in record.items {
    assert_eq(
      item.workspace,
      batch_item_workspace(data_root, record.id, item.key),
    )
  }
  let persisted = load_batch(data_root, record.id).unwrap()
  assert_eq(persisted.items[0].workspace, record.items[0].workspace)
  assert_eq(persisted.items[1].workspace, record.items[1].workspace)
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "runner consumes persisted retry requests once" {
  let data_root = @fs.tmpdir(prefix="moonsage-retry-control-test-")
  let record = create_batch(
    data_root,
    "batch-retry-control",
    default_batch_config(),
    [summary("acme/a", "https://github.com/acme/a")],
  )
  let failed = run_batch_once(data_root, record, (_) => {
    failed_audit_result("moon test failed", false)
  })
  let key = failed.items[0].key
  assert_true(failed.items[0].status is Failed)
  save_batch_control(data_root, failed.id, {
    pause: false,
    cancel: false,
    retry_items: [key],
    approved_items: [],
    updated_at_ms: 2L,
  })
  let retried = run_batch_once(data_root, failed, (item) => {
    verified_result(revision="retry-" + item.key)
  })
  assert_true(retried.items[0].status is VerifiedPendingPublish)
  assert_eq(retried.items[0].attempts, 2)
  assert_true(load_batch_control(data_root, failed.id).retry_items.is_empty())
  assert_true(load_batch(data_root, failed.id).unwrap().status is Completed)
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "concurrent stage callbacks merge persisted item state" {
  let data_root = @fs.tmpdir(prefix="moonsage-stage-state-test-")
  let record = create_batch(
    data_root,
    "batch-stage-state",
    { ..default_batch_config(), concurrency: 2 },
    [
      summary("acme/a", "https://github.com/acme/a"),
      summary("acme/b", "https://github.com/acme/b"),
    ],
  )
  for item in record.items {
    item.status = Fetching
    item.attempts = 1
  }
  save_batch(data_root, record)
  let updates : Array[async () -> Bool] = record.items.map(fn(item) {
    () =>
      update_batch_item_stage_by_id(
        data_root,
        record.id,
        item.key,
        "auditing",
        attempts=1,
      )
  })
  let results = @async.all(updates, max_concurrent=2)
  assert_true(results.all(fn(value) { value }))
  let auditing = load_batch(data_root, record.id).unwrap()
  assert_true(auditing.items.all(fn(item) { item.status is Auditing }))
  let first = auditing.items[0]
  assert_true(
    update_batch_item_stage_by_id(
      data_root,
      record.id,
      first.key,
      "fetching",
      attempts=2,
    ),
  )
  let retried = load_batch(data_root, record.id).unwrap().find_item(first.key).unwrap()
  assert_true(retried.status is Fetching)
  assert_eq(retried.attempts, 2)
  assert_true(
    !update_batch_item_stage_by_id(
      data_root,
      record.id,
      first.key,
      "unknown",
      attempts=2,
    ),
  )
  assert_eq(load_batch_events(data_root, record.id).length(), 7)
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "publisher honors auto cap approvals and retry budget" {
  let data_root = @fs.tmpdir(prefix="moonsage-publish-queue-test-")
  let config = {
    ..default_batch_config(),
    max_prs: 1,
    network_retries: 2,
  }
  let record = create_batch(
    data_root,
    "batch-publish-queue",
    config,
    [
      summary("acme/a", "https://github.com/acme/a"),
      summary("acme/b", "https://github.com/acme/b"),
      summary("acme/c", "https://github.com/acme/c"),
    ],
  )
  for item in record.items {
    item.status = Verifying
    let result = if item.key == "acme--c" {
      verified_result(path=".github/workflows/release.yml")
    } else {
      verified_result(path="src/" + item.repo + ".mbt")
    }
    apply_audit_result(record, item, {
      ..result,
      workspace: item.workspace,
      project_dir: item.workspace + "/attempt-1/repo",
      source_revision: "rev-" + item.key,
    }, 2L)
  }
  save_batch(data_root, record)
  save_batch_control(data_root, record.id, {
    pause: false,
    cancel: false,
    retry_items: [],
    approved_items: ["acme--c"],
    updated_at_ms: 3L,
  })
  let attempts : Map[String, Int] = Map([])
  let published = publish_ready_batch_items(data_root, record, (request) => {
    let count = attempts.get(request.item_key).unwrap_or(0) + 1
    attempts[request.item_key] = count
    if request.item_key == "acme--c" && count == 1 {
      {
        created: false,
        pr_url: "",
        error: "temporary GitHub error",
        retryable: true,
      }
    } else {
      {
        created: true,
        pr_url: "https://github.com/" + request.owner + "/" + request.repo + "/pull/1",
        error: "",
        retryable: false,
      }
    }
  })
  assert_true(published.find_item("acme--a").unwrap().status is Created)
  assert_true(
    published.find_item("acme--b").unwrap().status is VerifiedPendingPublish,
  )
  assert_true(published.find_item("acme--c").unwrap().status is Created)
  assert_eq(published.pr_count, 2)
  assert_eq(attempts.get("acme--a"), Some(1))
  assert_eq(attempts.get("acme--b"), None)
  assert_eq(attempts.get("acme--c"), Some(2))
  assert_true(
    load_batch_control(data_root, record.id).approved_items.is_empty(),
  )
  @fs.rmdir(data_root, recursive=true)
}

///|
async test "run by id refuses lock contention and releases its own lock" {
  let data_root = @fs.tmpdir(prefix="moonsage-run-lock-test-")
  let record = create_batch(
    data_root,
    "batch-run-lock",
    default_batch_config(),
    [summary("acme/a", "https://github.com/acme/a")],
  )
  assert_true(try_acquire_batch_lock(data_root, record.id, "held-worker"))
  let blocked = run_batch_by_id(data_root, record.id, (_) => {
    verified_result()
  }).unwrap()
  assert_eq(blocked.last_error, "batch is already running")
  assert_true(blocked.items[0].status is Queued)
  release_batch_lock(data_root, record.id)
  let finished = run_batch_by_id(data_root, record.id, (item) => {
    verified_result(revision="locked-" + item.key)
  }).unwrap()
  assert_true(finished.status is Completed)
  assert_true(finished.items[0].status is VerifiedPendingPublish)
  assert_true(try_acquire_batch_lock(data_root, record.id, "after-worker"))
  release_batch_lock(data_root, record.id)
  @fs.rmdir(data_root, recursive=true)
}
