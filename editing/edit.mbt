///|
// 一次精确编辑：在 file 的 [start_line, end_line] 行区间内，把 old_string
// 替换为 new_string。old_string 为空表示在 start_line 行首插入；
// end_line 为 0 表示到文件末尾。
pub(all) struct EditSpec {
  file : String
  old_string : String
  new_string : String
  start_line : Int
  end_line : Int
}

///|
// 每行起始的字符偏移（1-based，第 1 行恒为 0）。
fn line_starts(content : String) -> Array[Int] {
  let starts : Array[Int] = [0]
  let mut i = 0
  while i < content.length() {
    if content[i] == '\n' {
      starts.push(i + 1)
    }
    i += 1
  }
  starts
}

///|
fn line_of_offset(starts : Array[Int], offset : Int) -> Int {
  let mut line = 1
  for i = 1; i < starts.length(); i = i + 1 {
    if starts[i] <= offset {
      line = i + 1
    }
  }
  line
}

///|
fn find_all_offsets(content : String, needle : String) -> Array[Int] {
  let out : Array[Int] = []
  let needle_len = needle.length()
  if needle_len == 0 {
    return out
  }
  let mut offset = 0
  for ;; {
    match content[offset:].find(needle) {
      Some(idx) => {
        out.push(offset + idx)
        offset = offset + idx + 1
      }
      None => break
    }
  }
  out
}

///|
// 计算 normalized（CRLF→LF）到原始内容的字符偏移映射。
fn eol_offset_map(content : String) -> Array[Int] {
  let map : Array[Int] = []
  let mut ci = 0
  while ci < content.length() {
    if ci + 1 < content.length() &&
      content[ci] == '\r' &&
      content[ci + 1] == '\n' {
      // normalized 中该位置对应原始的 '\n'（跳过 '\r'）
      map.push(ci + 1)
      ci += 2
    } else {
      map.push(ci)
      ci += 1
    }
  }
  map
}

///|
// 把 new_string 的换行统一为与文件一致的风格，避免混用 LF/CRLF。
fn normalize_new_eol(s : String, crlf : Bool) -> String {
  let s = s.replace_all(old="\r\n", new="\n")
  if crlf {
    s.replace_all(old="\n", new="\r\n")
  } else {
    s
  }
}

///|
// 把同一个文件上的一组编辑应用到原内容，返回新内容。
// 校验：每个非空 old_string 必须在行区间内恰好匹配一次；编辑区间不得重叠。
// 插入（old_string 为空）定位到 start_line 行首，超出行数则追加到文件末尾。
// 匹配对换行符不敏感（CRLF 与 LF 视为等价），输出保留原文件换行风格。
pub fn apply_edits_to_file(
  content : String,
  edits : Array[EditSpec],
) -> String raise {
  let normalized = content.replace_all(old="\r\n", new="\n")
  let orig = eol_offset_map(content)
  let crlf = content.contains("\r\n")
  let starts = line_starts(normalized)
  let line_count = starts.length()
  let ranges : Array[(Int, Int, EditSpec)] = []
  for edit in edits {
    if edit.old_string == "" {
      let line = if edit.start_line < 1 {
        1
      } else if edit.start_line > line_count {
        line_count + 1
      } else {
        edit.start_line
      }
      let insert_at = if line > line_count {
        normalized.length()
      } else {
        starts[line - 1]
      }
      ranges.push((insert_at, insert_at, edit))
    } else {
      let old_norm = edit.old_string.replace_all(old="\r\n", new="\n")
      let matches = find_all_offsets(normalized, old_norm)
      let in_range : Array[Int] = []
      for m in matches {
        let start_line = line_of_offset(starts, m)
        let end_line = line_of_offset(starts, m + old_norm.length() - 1)
        let limit = if edit.end_line == 0 { line_count } else { edit.end_line }
        if start_line >= edit.start_line && end_line <= limit {
          in_range.push(m)
        }
      }
      let limit = if edit.end_line == 0 { line_count } else { edit.end_line }
      guard in_range.length() == 1 else {
        fail(
          "multi_edit: \{edit.file} 中 old_string 在行 \{edit.start_line}..\{limit} 内匹配 \{in_range.length()} 次，需要恰好 1 次",
        )
      }
      ranges.push((in_range[0], in_range[0] + old_norm.length(), edit))
    }
  }
  ranges.sort_by(fn(a, b) { a.0 - b.0 })
  for i = 1; i < ranges.length(); i = i + 1 {
    if ranges[i].0 < ranges[i - 1].1 {
      fail("multi_edit: 编辑区间重叠")
    }
  }
  let mut result = content
  for i = ranges.length() - 1; i >= 0; i = i - 1 {
    let (start_norm, end_norm, edit) = ranges[i]
    let start = if start_norm >= orig.length() {
      content.length()
    } else {
      orig[start_norm]
    }
    let end = if end_norm >= orig.length() {
      content.length()
    } else {
      orig[end_norm]
    }
    // 若端点落在 CRLF 的 '\n' 上，回退到 '\r'，避免把换行符从中间切开。
    let end = if end > 0 &&
      end < content.length() &&
      content[end] == '\n' &&
      content[end - 1] == '\r' {
      end - 1
    } else {
      end
    }
    let out = StringBuilder::new()
    out.write_stringview(result[:start])
    out.write_string(normalize_new_eol(edit.new_string, crlf))
    out.write_stringview(result[end:])
    result = out.to_string()
  }
  result
}
