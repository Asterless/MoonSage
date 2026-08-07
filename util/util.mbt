///|
// Reads a string field from a tool-argument JSON document.
// Returns an empty string when the key is missing or not a string.
pub fn json_string_arg(document : Json, key : String) -> String {
  match document {
    Object(fields) =>
      match fields.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
// Resolves a project-relative path against the root, rejecting traversal,
// absolute paths and backslashes.
pub fn safe_path(root : String, rel : String) -> String raise {
  guard rel != "" &&
    !rel.contains("..") &&
    !rel.contains("\\") &&
    !rel.contains(":") &&
    !rel.has_prefix("/") &&
    !rel.has_prefix("\\") else {
    fail("invalid path: \{rel}")
  }
  root + "/" + rel
}

///|
pub fn parse_int_or(s : String, default : Int) -> Int {
  @string.parse_int(s) catch {
    _ => default
  }
}

///|
pub fn basename(path : String) -> String {
  let parts = path.split("/").to_array()
  parts[parts.length() - 1].to_owned()
}
