///|
fn unique_batch_keys(values : Array[String], extra : String) -> Array[String] {
  let result = values.copy()
  if extra != "" && !result.contains(extra) {
    result.push(extra)
  }
  result
}

///|
async fn write_batch_control_action(
  data_root : String,
  id : String,
  action : String,
  item_key? : String = "",
) -> Unit {
  let previous = @batch.load_batch_control(data_root, id)
  let next : @batch.BatchControl = match action {
    "pause" => { ..previous, pause: true, updated_at_ms: @async.now() }
    "cancel" =>
      { ..previous, pause: false, cancel: true, updated_at_ms: @async.now() }
    "resume" =>
      { ..previous, pause: false, cancel: false, updated_at_ms: @async.now() }
    "retry" =>
      {
        ..previous,
        pause: false,
        cancel: false,
        retry_items: unique_batch_keys(previous.retry_items, item_key),
        updated_at_ms: @async.now(),
      }
    "publish" =>
      {
        ..previous,
        pause: false,
        cancel: false,
        approved_items: unique_batch_keys(previous.approved_items, item_key),
        updated_at_ms: @async.now(),
      }
    _ => fail("unknown batch control action: \{action}")
  }
  @batch.save_batch_control(data_root, id, next)
}

///|
async fn run_batch_start_command(
  m : @argparse.Matches,
  data_root : String,
  stream_json : Bool,
) -> Unit {
  let worker = flag_of(m, "worker")
  let resume_id = batch_value(m, "resume")
  let id = if worker {
    required_batch_id(m)
  } else if resume_id != "" {
    @batch.validate_storage_id(resume_id)
    resume_id
  } else {
    let config = batch_config_from_matches(m)
    let new_id = new_batch_id()
    let record = @batch.BatchRecord::new(new_id, config, [], @async.now())
    @batch.save_batch(data_root, record, secrets=batch_secret_values())
    @batch.save_batch_control(data_root, new_id, @batch.empty_batch_control())
    new_id
  }
  if resume_id != "" {
    write_batch_control_action(data_root, id, "resume")
  }
  let record = run_mode1_worker(data_root, id, stream_json)
  if !stream_json {
    print_batch_record(record)
  }
}

///|
async fn run_batch_control_command(
  m : @argparse.Matches,
  data_root : String,
  operation : String,
) -> Unit {
  let id = required_batch_id(m)
  guard @batch.load_batch(data_root, id) is Some(record) else {
    fail("batch not found: \{id}")
  }
  match operation {
    "pause" => {
      guard record.status is (@batch.Running | @batch.Watching) else {
        fail("only a running or watching batch can be paused")
      }
      write_batch_control_action(data_root, id, "pause")
      print_batch_record(record)
    }
    "cancel" => {
      guard !(record.status is (@batch.Completed | @batch.Cancelled)) else {
        fail("completed or cancelled batches cannot be cancelled")
      }
      write_batch_control_action(data_root, id, "cancel")
      print_batch_record(record)
    }
    "resume" => {
      write_batch_control_action(data_root, id, "resume")
      let resumed = run_mode1_worker(data_root, id, flag_of(m, "stream-json"))
      if !flag_of(m, "stream-json") {
        print_batch_record(resumed)
      }
    }
    "retry" => {
      let item_key = required_batch_item(m)
      guard record.find_item(item_key) is Some(item) else {
        fail("batch item not found: \{item_key}")
      }
      guard item.status
        is (@batch.Failed
        | @batch.Cancelled
        | @batch.Skipped
        | @batch.NoChanges) else {
        fail("item cannot be retried from \{item.status.to_string()}")
      }
      if flag_of(m, "force") {
        ignore(
          @batch.retry_batch_item_by_id(data_root, id, item_key, force=true),
        )
      } else {
        write_batch_control_action(data_root, id, "retry", item_key~)
      }
      let retried = run_mode1_worker(data_root, id, flag_of(m, "stream-json"))
      if !flag_of(m, "stream-json") {
        print_batch_record(retried)
      }
    }
    "publish" => {
      let item_key = required_batch_item(m)
      guard record.find_item(item_key) is Some(item) else {
        fail("batch item not found: \{item_key}")
      }
      guard item.status is @batch.VerifiedPendingPublish else {
        fail("only verified_pending_publish items can be approved")
      }
      write_batch_control_action(data_root, id, "publish", item_key~)
      let published = run_mode1_worker(data_root, id, flag_of(m, "stream-json"))
      if !flag_of(m, "stream-json") {
        print_batch_record(published)
      }
    }
    _ => fail("unknown batch control action: \{operation}")
  }
}
