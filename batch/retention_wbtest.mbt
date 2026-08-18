///|
let retention_test_day_ms : Int64 = 24L * 60L * 60L * 1000L

///|
fn retention_test_modules(count : Int) -> Array[BatchModule] {
  Array::makei(count, fn(index) {
    let suffix = index.to_string()
    {
      key: "acme--repo-" + suffix,
      owner: "acme",
      repo: "repo-" + suffix,
      repository: "https://github.com/acme/repo-" + suffix,
      primary_name: "acme/repo-" + suffix,
      module_names: ["acme/repo-" + suffix],
      version: "1.0.0",
    }
  })
}

///|
async fn create_retention_workspace(
  data_root : String,
  batch_id : String,
  item_key : String,
) -> String {
  let path = batch_item_workspace(data_root, batch_id, item_key)
  @fs.mkdir(path, recursive=true)
  @fs.write_file(
    path + "/marker.txt",
    "retained",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  path
}

///|
async fn persist_retention_fixture(
  data_root : String,
  record : BatchRecord,
) -> Unit {
  save_batch(data_root, record)
  append_batch_event(
    data_root,
    BatchEvent::new("batch_state", record.id, record.updated_at_ms),
  )
  save_batch_control(data_root, record.id, {
    ..empty_batch_control(),
    updated_at_ms: record.updated_at_ms,
  })
  assert_true(try_acquire_batch_lock(data_root, record.id, "test-worker"))
}

///|
test "retention boundaries distinguish item and batch terminal states" {
  let now_ms = 100L * retention_test_day_ms
  let record = BatchRecord::new(
    "batch-boundaries",
    default_batch_config(),
    retention_test_modules(1),
    0L,
  )
  let item = record.items[0]
  for status in [Created, NoChanges, Skipped] {
    item.status = status
    item.updated_at_ms = now_ms + retention_test_day_ms
    assert_true(batch_item_workspace_retention_due(item, now_ms))
  }
  item.status = Failed
  item.updated_at_ms = now_ms - 7L * retention_test_day_ms + 1L
  assert_true(!batch_item_workspace_retention_due(item, now_ms))
  item.updated_at_ms = now_ms - 7L * retention_test_day_ms
  assert_true(batch_item_workspace_retention_due(item, now_ms))
  item.status = VerifiedPendingPublish
  item.updated_at_ms = 0L
  assert_true(!batch_item_workspace_retention_due(item, now_ms))
  let resumable_statuses : Array[BatchStatus] = [Queued, Running, Paused, Watching]
  for status in resumable_statuses {
    record.status = status
    record.updated_at_ms = 0L
    assert_true(!batch_history_retention_due(record, now_ms))
  }
  for status in [Completed, Failed, Cancelled] {
    record.status = status
    record.updated_at_ms = now_ms - 90L * retention_test_day_ms + 1L
    assert_true(!batch_history_retention_due(record, now_ms))
    record.updated_at_ms = now_ms - 90L * retention_test_day_ms
    assert_true(batch_history_retention_due(record, now_ms))
  }
}

///|
async test "item retention removes only canonical eligible workspaces" {
  let data_root = @fs.tmpdir(prefix="moonsage-retention-items-")
  let outside = @fs.tmpdir(prefix="moonsage-retention-outside-")
  let now_ms = 100L * retention_test_day_ms
  let record = BatchRecord::new(
    "batch-item-retention",
    default_batch_config(),
    retention_test_modules(6),
    0L,
  )
  let statuses = [
    Created,
    NoChanges,
    Skipped,
    Failed,
    Failed,
    VerifiedPendingPublish,
  ]
  let paths : Array[String] = []
  for index, item in record.items {
    item.status = statuses[index]
    item.updated_at_ms = if index == 3 {
      now_ms - 7L * retention_test_day_ms
    } else if index == 4 {
      now_ms - 7L * retention_test_day_ms + 1L
    } else {
      now_ms
    }
    paths.push(create_retention_workspace(data_root, record.id, item.key))
  }
  record.items[0].workspace = outside
  @fs.write_file(
    outside + "/outside.txt",
    "must remain",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  assert_eq(cleanup_batch_item_workspaces(data_root, record, now_ms), 4)
  for index in 0..<4 {
    assert_true(!@fs.exists(paths[index]))
  }
  assert_true(@fs.exists(paths[4]))
  assert_true(@fs.exists(paths[5]))
  assert_true(@fs.exists(outside + "/outside.txt"))
  @fs.rmdir(data_root, recursive=true)
  @fs.rmdir(outside, recursive=true)
}

///|
async test "batch retention removes old terminal artifacts and preserves active records" {
  let data_root = @fs.tmpdir(prefix="moonsage-retention-batches-")
  let now_ms = 100L * retention_test_day_ms
  let expired = BatchRecord::new(
    "batch-expired",
    default_batch_config(),
    retention_test_modules(1),
    0L,
  )
  expired.status = Completed
  expired.updated_at_ms = now_ms - 90L * retention_test_day_ms
  let expired_workspace = create_retention_workspace(
    data_root,
    expired.id,
    expired.items[0].key,
  )
  persist_retention_fixture(data_root, expired)
  let recent = BatchRecord::new(
    "batch-recent",
    default_batch_config(),
    retention_test_modules(1),
    0L,
  )
  recent.status = Failed
  recent.updated_at_ms = now_ms - 90L * retention_test_day_ms + 1L
  let recent_workspace = create_retention_workspace(
    data_root,
    recent.id,
    recent.items[0].key,
  )
  persist_retention_fixture(data_root, recent)
  let active_statuses : Array[BatchStatus] = [Queued, Running, Paused, Watching]
  let active_ids : Array[String] = []
  for index, status in active_statuses {
    let id = "batch-active-" + index.to_string()
    let active = BatchRecord::new(
      id,
      default_batch_config(),
      retention_test_modules(1),
      0L,
    )
    active.status = status
    active.updated_at_ms = 0L
    ignore(create_retention_workspace(data_root, id, active.items[0].key))
    persist_retention_fixture(data_root, active)
    active_ids.push(id)
  }
  let report = cleanup_batch_retention(data_root, now_ms)
  assert_eq(report.batches_removed, 1)
  assert_eq(report.item_workspaces_removed, 0)
  assert_true(!@fs.exists(expired_workspace))
  assert_true(!@fs.exists(batch_record_path(data_root, expired.id)))
  assert_true(!@fs.exists(batch_events_path(data_root, expired.id)))
  assert_true(!@fs.exists(batch_control_path(data_root, expired.id)))
  assert_true(!@fs.exists(batch_lock_path(data_root, expired.id)))
  assert_true(@fs.exists(recent_workspace))
  assert_true(@fs.exists(batch_record_path(data_root, recent.id)))
  for id in active_ids {
    assert_true(@fs.exists(batch_record_path(data_root, id)))
    assert_true(@fs.exists(batch_events_path(data_root, id)))
    assert_true(@fs.exists(batch_control_path(data_root, id)))
    assert_true(@fs.exists(batch_lock_path(data_root, id)))
  }
  @fs.rmdir(data_root, recursive=true)
}
