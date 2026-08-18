///|
fn batch_audit_command() -> @argparse.Command {
  @argparse.Command(
    "batch-audit",
    about="Audit, fix, verify and publish Mooncakes repositories in batches.",
    options=[
      @argparse.OptionArg("interval", long="interval", about="Watch interval (default: 6h)."),
      @argparse.OptionArg("limit", long="limit", about="Maximum repositories; 0 means unlimited."),
      @argparse.OptionArg(
        "include",
        long="include",
        action=Append,
        about="Module name or glob to include; repeatable.",
      ),
      @argparse.OptionArg(
        "owner",
        long="owner",
        action=Append,
        about="Registry or repository owner; repeatable.",
      ),
      @argparse.OptionArg(
        "keyword",
        long="keyword",
        action=Append,
        about="Required module keyword; repeatable.",
      ),
      @argparse.OptionArg(
        "exclude",
        long="exclude",
        action=Append,
        about="Module name glob to exclude; repeatable.",
      ),
      @argparse.OptionArg("concurrency", long="concurrency", about="Concurrent packages (1-4)."),
      @argparse.OptionArg("max-prs", long="max-prs", about="Ready PR limit per cycle."),
      @argparse.OptionArg("package-timeout", long="package-timeout", about="Per-package timeout (default: 20m)."),
      @argparse.OptionArg("max-calls", long="max-calls", about="Maximum fix tool calls per package."),
      @argparse.OptionArg("resume", long="resume", about="Resume an existing batch id."),
      @argparse.OptionArg("item", long="item", about="Repository item key for retry or publish."),
      @argparse.OptionArg(
        "batch-id",
        long="batch-id",
        about="Internal worker batch id.",
        hidden=true,
      ),
    ],
    flags=[
      @argparse.FlagArg("watch", long="watch", about="Refresh Mooncakes continuously."),
      @argparse.FlagArg("stream-json", long="stream-json", about="Write batch events as JSON Lines."),
      @argparse.FlagArg("worker", long="worker", about="Run as a Web worker.", hidden=true),
      @argparse.FlagArg("force", long="force", about="Force a settled item to be retried."),
    ],
    positionals=[
      @argparse.PositionArg(
        "operation",
        num_args=@argparse.ValueRange(lower=0, upper=1),
        about="start, status, pause, resume, cancel, retry, or publish.",
      ),
      @argparse.PositionArg(
        "batch",
        num_args=@argparse.ValueRange(lower=0, upper=1),
        about="Batch id for control operations.",
      ),
    ],
  )
}

///|
fn root_command() -> @argparse.Command {
  @argparse.Command(
    "moonsage",
    about="MoonSage - an agent for the MoonBit package ecosystem",
    flags=[
      @argparse.FlagArg(
        "version",
        short='V',
        about="Print version information.",
      ),
    ],
    subcommands=[
      @argparse.Command(
        "chat",
        about="Start the classic line-oriented chat; exit with /exit or /quit.",
        options=[
          @argparse.OptionArg(
            "session",
            long="session",
            about="Resume or create this durable session id.",
          ),
        ],
        flags=[
          @argparse.FlagArg(
            "continue",
            long="continue",
            about="Resume the most recent durable session.",
          ),
        ],
      ),
      @argparse.Command(
        "tui",
        about="Start the interactive terminal UI; exit with /exit or /quit.",
        options=[
          @argparse.OptionArg(
            "session",
            long="session",
            about="Resume or create this durable session id.",
          ),
        ],
        flags=[
          @argparse.FlagArg(
            "continue",
            long="continue",
            about="Resume the most recent durable session.",
          ),
        ],
      ),
      @argparse.Command("search", about="Search Mooncakes modules.", positionals=[
        @argparse.PositionArg(
          "keywords",
          num_args=@argparse.ValueRange(lower=0),
          about="Search keywords.",
        ),
      ]),
      @argparse.Command(
        "ask",
        about="Ask a one-shot question.",
        options=[
          @argparse.OptionArg(
            "input-file",
            long="input-file",
            about="Read the UTF-8 question from a file instead of command-line arguments.",
          ),
        ],
        flags=[
          @argparse.FlagArg(
            "stream-json",
            long="stream-json",
            about="Write Agent lifecycle events as JSON Lines.",
          ),
        ],
        positionals=[
          @argparse.PositionArg(
            "question",
            num_args=@argparse.ValueRange(lower=0),
            about="Question text.",
          ),
        ],
      ),
      @argparse.Command(
        "task",
        about="Run a task against a local workspace.",
        options=[
          @argparse.OptionArg(
            "workspace",
            long="workspace",
            about="Workspace directory the task is allowed to access.",
          ),
          @argparse.OptionArg("cwd", long="cwd", about="Alias for --workspace."),
          @argparse.OptionArg(
            "permission",
            long="permission",
            about="Permission policy: read-only, controlled-write, or full-auto.",
          ),
          @argparse.OptionArg(
            "input-file",
            long="input-file",
            about="Read the task goal from a UTF-8 file.",
          ),
        ],
        flags=[
          @argparse.FlagArg(
            "stream-json",
            long="stream-json",
            about="Write Agent lifecycle events as JSON Lines.",
          ),
        ],
        positionals=[
          @argparse.PositionArg(
            "goal",
            num_args=@argparse.ValueRange(lower=0),
            about="Task goal.",
          ),
        ],
      ),
      @argparse.Command(
        "audit",
        about="Audit a remote Mooncakes package (optionally fix it).",
        options=[
          @argparse.OptionArg(
            "confirm",
            long="confirm",
            about="Confirmation mode: prompt, diff or yes.",
          ),
          @argparse.OptionArg(
            "workspace",
            long="workspace",
            about="Directory for the cloned project.",
          ),
          @argparse.OptionArg(
            "max-calls",
            long="max-calls",
            about="Maximum tool calls for the fix phase.",
          ),
        ],
        flags=[
          @argparse.FlagArg(
            "fix",
            long="fix",
            about="Apply fixes with verified local edits.",
          ),
          @argparse.FlagArg(
            "pr",
            long="pr",
            about="After fixing, push a branch and open a pull request.",
          ),
          @argparse.FlagArg(
            "clean",
            long="clean",
            about="Clean leftover audit workspaces.",
          ),
        ],
        positionals=[
          @argparse.PositionArg(
            "module",
            num_args=@argparse.ValueRange(lower=0),
            about="owner/module to audit.",
          ),
        ],
      ),
      batch_audit_command(),
    ],
  )
}

///|
fn normalize_mode_one_args(args : Array[String]) -> Array[String] {
  if args.length() >= 3 && args[1] == "mode" && args[2] == "1" {
    let normalized = [args[0], "batch-audit"]
    for index in 3..<args.length() {
      normalized.push(args[index])
    }
    normalized
  } else {
    args
  }
}

///|
const MOONSAGE_VERSION = "0.1.0"

///|
fn values_of(m : @argparse.Matches, key : String) -> Array[String] {
  match m.values.get(key) {
    Some(values) => values
    None => []
  }
}

///|
fn flag_of(m : @argparse.Matches, key : String) -> Bool {
  match m.flags.get(key) {
    Some(value) => value
    None => false
  }
}

///|
fn join_values(m : @argparse.Matches, key : String) -> String {
  join_query(values_of(m, key), 0)
}

///|
// 把 audit 子命令的解析结果还原成 audit.run_audit 接受的原始参数，
// 让 audit 自身的参数解析与测试保持不变。
fn audit_args(m : @argparse.Matches) -> Array[String] {
  let out : Array[String] = []
  for name in values_of(m, "module") {
    out.push(name)
  }
  if flag_of(m, "fix") {
    out.push("--fix")
  }
  if flag_of(m, "clean") {
    out.push("--clean")
  }
  if flag_of(m, "pr") {
    out.push("--pr")
  }
  match m.values.get("confirm") {
    Some([value, ..]) => {
      out.push("--confirm")
      out.push(value)
    }
    _ => ()
  }
  match m.values.get("workspace") {
    Some([value, ..]) => {
      out.push("--workspace")
      out.push(value)
    }
    _ => ()
  }
  match m.values.get("max-calls") {
    Some([value, ..]) => {
      out.push("--max-calls")
      out.push(value)
    }
    _ => ()
  }
  out
}
