///|
using @html {code, h2, h3, pre}

///|
fn is_block_start(line : String) -> Bool {
  line.has_prefix("# ") ||
  line.has_prefix("## ") ||
  line.has_prefix("### ") ||
  line.has_prefix("- ") ||
  line.has_prefix("```")
}

///|
fn find_code_end(lines : Array[String], index : Int) -> Int {
  if index >= lines.length() || lines[index].has_prefix("```") {
    index
  } else {
    find_code_end(lines, index + 1)
  }
}

///|
fn find_list_end(lines : Array[String], index : Int) -> Int {
  if index >= lines.length() || !lines[index].has_prefix("- ") {
    index
  } else {
    find_list_end(lines, index + 1)
  }
}

///|
fn find_paragraph_end(lines : Array[String], index : Int) -> Int {
  if index >= lines.length() ||
    lines[index].trim().is_empty() ||
    is_block_start(lines[index]) {
    index
  } else {
    find_paragraph_end(lines, index + 1)
  }
}

///|
fn render_markdown_blocks(
  lines : Array[String],
  index : Int,
  output : Array[Html],
) -> Array[Html] {
  if index >= lines.length() {
    output
  } else {
    let line = lines[index]
    if line.trim().is_empty() {
      render_markdown_blocks(lines, index + 1, output)
    } else if line.has_prefix("```") {
      let end_index = find_code_end(lines, index + 1)
      let source = lines[index + 1:end_index].join("\n")
      output.push(pre([code(source)]))
      render_markdown_blocks(
        lines,
        if end_index < lines.length() {
          end_index + 1
        } else {
          end_index
        },
        output,
      )
    } else if line.has_prefix("### ") {
      output.push(h3(line[4:].to_owned()))
      render_markdown_blocks(lines, index + 1, output)
    } else if line.has_prefix("## ") {
      output.push(h2(line[3:].to_owned()))
      render_markdown_blocks(lines, index + 1, output)
    } else if line.has_prefix("# ") {
      output.push(h2(line[2:].to_owned()))
      render_markdown_blocks(lines, index + 1, output)
    } else if line.has_prefix("- ") {
      let end_index = find_list_end(lines, index)
      let items : Array[Html] = [
        for item in lines[index:end_index] => li(item[2:].to_owned())
      ]
      output.push(ul(items))
      render_markdown_blocks(lines, end_index, output)
    } else {
      let end_index = find_paragraph_end(lines, index + 1)
      output.push(p(lines[index:end_index].join("\n")))
      render_markdown_blocks(lines, end_index, output)
    }
  }
}

///|
fn markdown_view(source : String) -> Array[Html] {
  render_markdown_blocks(
    source.split("\n").map(line => line.to_owned()).to_array(),
    0,
    [],
  )
}
