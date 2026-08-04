///|
/// Parse one `.env` line into a `(key, value)` pair.
/// Blank lines and lines starting with `#` are ignored.
/// Surrounding quotes are stripped from the value.
fn parse_env_line(line : StringView) -> (String, String)? {
  let trimmed = line.trim()
  if trimmed.is_empty() || trimmed.has_prefix("#") {
    return None
  }
  match trimmed.find("=") {
    Some(idx) => {
      let key = trimmed[:idx].trim().to_owned()
      if key == "" {
        return None
      }
      let value = unquote(trimmed[idx + 1:].trim().to_owned())
      Some((key, value))
    }
    None => None
  }
}

///|
fn unquote(value : String) -> String {
  let len = value.length()
  if len >= 2 {
    let first = value[0]
    let last = value[len - 1]
    if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
      return value[1:len - 1].to_owned()
    }
  }
  value
}

///|
fn parse_env_content(content : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for line in content.split("\n") {
    if parse_env_line(line) is Some(pair) {
      out.push(pair)
    }
  }
  out
}

///|
async fn read_text_file(path : String) -> String? {
  let file = @fs.open(path, mode=ReadOnly) catch { _ => return None }
  defer file.close()
  let content = file.read_all().text() catch { _ => return None }
  Some(content)
}

///|
/// Load a `.env` file into the process environment. Values already present
/// in the real environment take precedence and are never overwritten.
pub async fn load_dotenv(path : String) -> Unit {
  let content = match read_text_file(path) {
    Some(content) => content
    None => return
  }
  for pair in parse_env_content(content) {
    let (key, value) = pair
    if @sys.get_env_var(key) is None {
      @sys.set_env_var(key, value)
    }
  }
}
