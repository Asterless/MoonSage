///|
let failed_workspace_retention_ms : Int64 = 7L * 24L * 60L * 60L * 1000L

///|
let batch_history_retention_ms : Int64 = 90L * 24L * 60L * 60L * 1000L

///|
pub(all) struct BatchRetentionReport {
  item_workspaces_removed : Int
  batches_removed : Int
} derive(Eq, Debug)

///|
fn retention_period_elapsed(
  updated_at_ms : Int64,
  now_ms : Int64,
  retention_ms : Int64,
) -> Bool {
  now_ms >= updated_at_ms && now_ms - updated_at_ms >= retention_ms
}

///|
/// Returns whether an item's canonical clone workspace may be removed.
/// Successfully published, unchanged, and skipped items are eligible
/// immediately; failed items retain their workspace for seven days.
pub fn batch_item_workspace_retention_due(
  item : BatchItem,
  now_ms : Int64,
) -> Bool {
  match item.status {
    Created | NoChanges | Skipped | Cancelled => true
    Failed =>
      retention_period_elapsed(
        item.updated_at_ms,
        now_ms,
        failed_workspace_retention_ms,
      )
    _ => false
  }
}

///|
/// Returns whether all persisted artifacts for a terminal batch have reached
/// the 90-day retention boundary. Active and resumable batch states are never
/// eligible, regardless of their timestamp.
pub fn batch_history_retention_due(
  record : BatchRecord,
  now_ms : Int64,
) -> Bool {
  record.status is (Completed | Failed | Cancelled) &&
  retention_period_elapsed(
    record.updated_at_ms,
    now_ms,
    batch_history_retention_ms,
  )
}

///|
fn retention_batch_workspace_path(
  data_root : String,
  batch_id : String,
) -> String raise {
  validate_storage_id(batch_id)
  batch_storage_dir(data_root) + "/workspaces/" + batch_id
}

///|
async fn remove_retained_path(path : String, recursive : Bool) -> Bool {
  if !@fs.exists(path) {
    return true
  }
  let kind = @fs.kind(path, follow_symlink=false) catch { _ => return false }
  let removed = try {
    if kind is Directory {
      if !recursive {
        return false
      }
      @fs.rmdir(path, recursive=true)
    } else {
      // A workspace root may have been replaced with a symlink. Removing the
      // link itself avoids following it outside the canonical storage tree.
      @fs.remove(path)
    }
    true
  } catch {
    _ => false
  }
  removed && !@fs.exists(path)
}

///|
async fn cleanup_one_item_workspace(
  data_root : String,
  batch_id : String,
  item : BatchItem,
  now_ms : Int64,
) -> Bool {
  guard batch_item_workspace_retention_due(item, now_ms) else { return false }
  let path = batch_item_workspace(data_root, batch_id, item.key) catch {
    _ => return false
  }
  let existed = @fs.exists(path)
  if !existed {
    return false
  }
  remove_retained_path(path, true)
}

///|
/// Remove item workspaces whose retention period has elapsed. Paths are
/// always regenerated from validated IDs; the persisted `workspace` field is
/// deliberately ignored.
pub async fn cleanup_batch_item_workspaces(
  data_root : String,
  record : BatchRecord,
  now_ms : Int64,
) -> Int {
  let mut removed = 0
  for item in record.items {
    if cleanup_one_item_workspace(data_root, record.id, item, now_ms) {
      removed += 1
    }
  }
  removed
}

///|
async fn cleanup_expired_batch(
  data_root : String,
  record : BatchRecord,
) -> Bool {
  let workspace_path = retention_batch_workspace_path(data_root, record.id) catch {
    _ => return false
  }
  // Keep the record until every supporting artifact has been removed. If any
  // removal fails, a later sweep can retry using the still-present record.
  guard remove_retained_path(workspace_path, true) else { return false }
  let support_paths = [
    batch_events_path(data_root, record.id),
    batch_control_path(data_root, record.id),
    batch_lock_path(data_root, record.id),
  ] catch {
    _ => return false
  }
  for path in support_paths {
    guard remove_retained_path(path, false) else { return false }
  }
  let record_path = batch_record_path(data_root, record.id) catch {
    _ => return false
  }
  remove_retained_path(record_path, false)
}

///|
/// Apply workspace and batch-history retention to all valid persisted batch
/// records below `data_root`. This function performs filesystem operations
/// directly and never invokes a shell.
pub async fn cleanup_batch_retention(
  data_root : String,
  now_ms : Int64,
) -> BatchRetentionReport {
  let mut item_workspaces_removed = 0
  let mut batches_removed = 0
  for record in list_batches(data_root) {
    if batch_history_retention_due(record, now_ms) {
      if cleanup_expired_batch(data_root, record) {
        batches_removed += 1
      }
    } else {
      item_workspaces_removed += cleanup_batch_item_workspaces(
        data_root, record, now_ms,
      )
    }
  }
  { item_workspaces_removed, batches_removed }
}
