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
    ],
  )
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
