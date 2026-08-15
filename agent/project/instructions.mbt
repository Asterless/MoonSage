///|
let max_project_instruction_bytes = 12_000

///|
fn bounded_project_instructions(source : String, filename : String) -> String {
  if source == "" {
    return ""
  }
  let content = if source.length() > max_project_instruction_bytes {
    source[:max_project_instruction_bytes].to_owned() +
    "\n... [project instructions truncated]"
  } else {
    source
  }
  "\n\n<ProjectInstructions source=\"\{filename}\">\n\{content}\n</ProjectInstructions>"
}

///|
/// Load repository-local agent instructions. AGENTS.md is applied before
/// CLAUDE.md so a repository can retain guidance for both ecosystems without
/// silently ignoring either file. Each source is bounded independently.
pub async fn load_project_instructions(root : String) -> String {
  let output = StringBuilder::new()
  for filename in ["AGENTS.md", "CLAUDE.md"] {
    let content = @fs.read_file(root + "/" + filename).text() catch { _ => "" }
    output.write_string(bounded_project_instructions(content, filename))
  }
  output.to_string()
}
