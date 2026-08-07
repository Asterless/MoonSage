///|
// Run a command with a timeout, defaulting to git. On timeout the child
// process is cancelled and (-1, "<cmd> command timed out after N ms and was
// terminated") is returned, so a stuck network operation can never hang the
// whole session.
pub async fn run_cmd_with_timeout(
  args : Array[String],
  timeout_ms : Int,
  cwd? : String = "",
  cmd? : String = "git",
) -> (Int, String) {
  let payload = @async.with_timeout_opt(timeout_ms, async fn() {
    let (exit, _, err) = if cwd != "" {
      @process.collect_output(cmd, args, cwd~, no_console_window=true)
    } else {
      @process.collect_output(cmd, args, no_console_window=true)
    }
    (exit, err.text() catch { _ => "" })
  })
  match payload {
    Some(result) => result
    None =>
      (-1, "\{cmd} command timed out after \{timeout_ms} ms and was terminated")
  }
}
