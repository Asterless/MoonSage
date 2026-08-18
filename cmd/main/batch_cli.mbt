///|
fn batch_value(m : @argparse.Matches, name : String) -> String {
  match values_of(m, name) {
    [value, ..] => value
    _ => ""
  }
}

///|
/// MoonBit's Int is signed 32-bit on the native CLI target. Keep the CLI
/// duration bound below that limit while the persisted batch schema remains
/// Int-compatible.
let max_batch_duration_ms : Int = 2_000_000_000

///|
fn parse_batch_integer(
  raw : String,
  name : String,
  minimum : Int,
  maximum : Int,
) -> Int raise {
  let value = raw.trim().to_owned()
  guard value != "" else { fail("\{name} is required") }
  let mut result = 0
  for digit in value {
    guard digit >= '0' && digit <= '9' else {
      fail("\{name} must be an integer")
    }
    result = result * 10 + digit.to_int() - '0'.to_int()
    guard result <= maximum else {
      fail("\{name} must be between \{minimum} and \{maximum}")
    }
  }
  guard result >= minimum else {
    fail("\{name} must be between \{minimum} and \{maximum}")
  }
  result
}

///|
fn parse_batch_duration(
  raw : String,
  name : String,
  minimum_ms : Int,
  maximum_ms : Int,
) -> Int raise {
  let value = raw.trim().to_lower()
  guard value != "" else { fail("\{name} is required") }
  let (number, multiplier) = if value.has_suffix("ms") {
    (value[:value.length() - 2].to_owned(), 1)
  } else if value.has_suffix("s") {
    (value[:value.length() - 1].to_owned(), 1000)
  } else if value.has_suffix("m") {
    (value[:value.length() - 1].to_owned(), 60 * 1000)
  } else if value.has_suffix("h") {
    (value[:value.length() - 1].to_owned(), 60 * 60 * 1000)
  } else if value.has_suffix("d") {
    (value[:value.length() - 1].to_owned(), 24 * 60 * 60 * 1000)
  } else {
    fail("\{name} must use ms, s, m, h, or d")
  }
  let upper = maximum_ms / multiplier
  let amount = parse_batch_integer(number, name, 0, upper)
  let milliseconds = amount * multiplier
  guard milliseconds >= minimum_ms && milliseconds <= maximum_ms else {
    fail("\{name} is outside the supported range")
  }
  milliseconds
}

///|
fn batch_config_from_matches(m : @argparse.Matches) -> @batch.BatchConfig raise {
  let defaults = @batch.default_batch_config()
  let limit = match batch_value(m, "limit") {
    "" => defaults.limit
    value => parse_batch_integer(value, "limit", 0, 1000000)
  }
  let concurrency = match batch_value(m, "concurrency") {
    "" => defaults.concurrency
    value => parse_batch_integer(value, "concurrency", 1, 4)
  }
  let max_prs = match batch_value(m, "max-prs") {
    "" => defaults.max_prs
    value => parse_batch_integer(value, "max-prs", 0, 1000)
  }
  let package_timeout_ms = match batch_value(m, "package-timeout") {
    "" => defaults.package_timeout_ms
    value =>
      parse_batch_duration(value, "package-timeout", 1000, 24 * 60 * 60 * 1000)
  }
  let max_calls = match batch_value(m, "max-calls") {
    "" => defaults.max_calls
    value => parse_batch_integer(value, "max-calls", 1, 10000)
  }
  let interval_ms = match batch_value(m, "interval") {
    "" => defaults.interval_ms
    value =>
      parse_batch_duration(value, "interval", 1000, max_batch_duration_ms)
  }
  let config : @batch.BatchConfig = {
    includes: values_of(m, "include"),
    owners: values_of(m, "owner"),
    keywords: values_of(m, "keyword"),
    excludes: values_of(m, "exclude"),
    limit,
    concurrency,
    max_prs,
    package_timeout_ms,
    max_calls,
    network_retries: defaults.network_retries,
    watch: flag_of(m, "watch"),
    interval_ms,
    policy_hash: defaults.policy_hash,
  }
  @batch.validate_batch_config(config)
  config
}

///|
fn batch_data_root() -> String {
  let configured = @sys.get_env_var("MOONSAGE_DATA_DIR").unwrap_or("").trim()
  if configured != "" {
    return configured.to_owned()
  }
  let local_app_data = @sys.get_env_var("LOCALAPPDATA").unwrap_or("").trim()
  if local_app_data != "" {
    return local_app_data.trim_end(chars="/\\").to_owned() + "/MoonSage"
  }
  let app = @sys.get_env_var("APPDATA").unwrap_or("").trim()
  if app != "" {
    return app.trim_end(chars="/\\").to_owned() + "/MoonSage"
  }
  let xdg = @sys.get_env_var("XDG_DATA_HOME").unwrap_or("").trim()
  if xdg != "" {
    return xdg.trim_end(chars="/\\").to_owned() + "/moonsage"
  }
  let home = @sys.get_env_var("HOME")
    .unwrap_or(@sys.get_env_var("USERPROFILE").unwrap_or(""))
    .trim()
  if home != "" {
    home.trim_end(chars="/\\").to_owned() + "/.local/share/moonsage"
  } else {
    @env.current_dir().unwrap_or(".") + "/.moonsage"
  }
}

///|
fn new_batch_id() -> String {
  "batch-" + @async.now().to_string()
}

///|
async fn write_batch_event(event : @batch.BatchEvent) -> Unit {
  @stdio.stdout.write(event.to_json().stringify() + "\n")
}

///|
async fn print_batch_record(record : @batch.BatchRecord) -> Unit {
  @stdio.stdout.write(record.to_json().stringify() + "\n")
}

///|
async fn batch_command_error(message : String, stream_json : Bool) -> Unit {
  if stream_json {
    write_batch_event(
      @batch.BatchEvent::new("error", "", @async.now(), message~),
    ) catch {
      _ => ()
    }
  } else {
    @stdio.stderr.write("error: " + message + "\n") catch {
      _ => ()
    }
  }
}

///|
fn required_batch_id(m : @argparse.Matches) -> String raise {
  let id = match batch_value(m, "batch") {
    "" => batch_value(m, "batch-id")
    value => value
  }
  guard id != "" else { fail("batch id is required") }
  @batch.validate_storage_id(id)
  id
}

///|
fn required_batch_item(m : @argparse.Matches) -> String raise {
  let item = batch_value(m, "item")
  guard item != "" else { fail("--item is required") }
  @batch.validate_storage_id(item)
  item
}

///|
fn batch_operation(m : @argparse.Matches) -> String {
  match values_of(m, "operation") {
    [value, ..] => value.to_lower()
    _ => "start"
  }
}

///|
async fn run_batch_audit_command(m : @argparse.Matches) -> Unit {
  let stream_json = flag_of(m, "stream-json")
  let operation = batch_operation(m)
  let data_root = batch_data_root()
  try {
    match operation {
      "start" => run_batch_start_command(m, data_root, stream_json)
      "status" => {
        let id = required_batch_id(m)
        match @batch.get_batch_status(data_root, id) {
          Some(record) => print_batch_record(record)
          None => fail("batch not found: \{id}")
        }
      }
      "pause" => run_batch_control_command(m, data_root, "pause")
      "resume" => run_batch_control_command(m, data_root, "resume")
      "cancel" => run_batch_control_command(m, data_root, "cancel")
      "retry" => run_batch_control_command(m, data_root, "retry")
      "publish" => run_batch_control_command(m, data_root, "publish")
      _ => fail("unknown batch-audit operation: \{operation}")
    }
  } catch {
    error => batch_command_error(error.to_string(), stream_json)
  }
}
